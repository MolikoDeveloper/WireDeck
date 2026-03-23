#include "config_store.h"
#include "cuda_probe.h"
#include "wiredeck_cuda_denoiser_shared.h"

#include "lv2/core/lv2.h"
#include "lv2/ui/ui.h"

#include <gtk/gtk.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WD_LEVEL_HISTORY_CAPACITY 4096
#define WD_LEVEL_HISTORY_WINDOW_SECONDS 5.0

typedef struct WireDeckLevelSample {
  double timestamp_seconds;
  float input_level;
  float output_level;
  float suppressed_noise_level;
  float voice_preservation_level;
} WireDeckLevelSample;

typedef struct WireDeckCudaDenoiserUI {
  LV2UI_Write_Function write;
  LV2UI_Controller controller;

  GtkWidget* root;
  GtkWidget* folder_button;
  GtkWidget* model_combo;
  GtkWidget* gpu_combo;
  GtkWidget* threshold_scale;
  GtkWidget* buffer_ms_scale;
  GtkWidget* mix_scale;
  GtkWidget* output_gain_scale;
  GtkWidget* status_label;
  GtkWidget* cuda_label;
  GtkWidget* model_info_label;
  GtkWidget* level_history_area;
  GtkWidget* level_history_caption;
  GtkWidget* model_loaded_label;
  GtkWidget* runtime_phase_label;

  WireDeckCudaProbeInfo cuda_info;
  WireDeckCudaDenoiserConfig config;
  WireDeckModelScanResult models;
  WireDeckWdgpMetadata selected_metadata;

  float threshold_value;
  float buffer_ms_value;
  float mix_value;
  float output_gain_db_value;
  float input_level_value;
  float output_level_value;
  float suppressed_noise_level_value;
  float voice_preservation_level_value;
  float model_loaded_value;
  float runtime_phase_value;
  WireDeckLevelSample level_history[WD_LEVEL_HISTORY_CAPACITY];
  uint32_t level_history_start;
  uint32_t level_history_count;
  guint refresh_timer_id;
  int gpu_index_value;
  int model_index_value;
  int updating;
  int widgets_alive;
} WireDeckCudaDenoiserUI;

static void
wd_ui_refresh_runtime_debug(WireDeckCudaDenoiserUI* ui);

static void
wd_ui_on_root_destroy(GtkWidget* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  (void)widget;

  if (!ui) {
    return;
  }

  ui->widgets_alive = 0;
  if (ui->refresh_timer_id != 0u) {
    g_source_remove(ui->refresh_timer_id);
    ui->refresh_timer_id = 0u;
  }
  ui->root = NULL;
  ui->folder_button = NULL;
  ui->model_combo = NULL;
  ui->gpu_combo = NULL;
  ui->threshold_scale = NULL;
  ui->buffer_ms_scale = NULL;
  ui->mix_scale = NULL;
  ui->output_gain_scale = NULL;
  ui->status_label = NULL;
  ui->cuda_label = NULL;
  ui->model_info_label = NULL;
  ui->level_history_area = NULL;
  ui->level_history_caption = NULL;
  ui->model_loaded_label = NULL;
  ui->runtime_phase_label = NULL;
}

static const char*
wd_ui_runtime_phase_label(int phase)
{
  switch ((WireDeckCudaDenoiserRuntimePhase)phase) {
  case WD_RUNTIME_IDLE:
    return "Idle";
  case WD_RUNTIME_LOADING:
    return "Loading";
  case WD_RUNTIME_RUNNING:
    return "Running";
  case WD_RUNTIME_ERROR:
    return "Error";
  case WD_RUNTIME_BYPASS:
    return "Bypass";
  default:
    return "Unknown";
  }
}

static void
wd_ui_clear_combo_box_text(GtkWidget* combo)
{
  GtkTreeModel* model;
  if (!combo) {
    return;
  }
  model = gtk_combo_box_get_model(GTK_COMBO_BOX(combo));
  if (model) {
    gtk_list_store_clear(GTK_LIST_STORE(model));
  }
}

static void
wd_ui_write_control(WireDeckCudaDenoiserUI* ui, uint32_t port_index, float value)
{
  if (!ui || !ui->write) {
    return;
  }
  ui->write(ui->controller, port_index, sizeof(float), 0, &value);
}

static void
wd_ui_trim_level_history(WireDeckCudaDenoiserUI* ui, double cutoff_seconds)
{
  if (!ui) {
    return;
  }

  while (ui->level_history_count > 0) {
    WireDeckLevelSample* sample = &ui->level_history[ui->level_history_start];
    if (sample->timestamp_seconds >= cutoff_seconds) {
      break;
    }
    ui->level_history_start = (ui->level_history_start + 1u) % WD_LEVEL_HISTORY_CAPACITY;
    --ui->level_history_count;
  }
}

static void
wd_ui_clamp_level(float* value, float max_level)
{
  if (!value) {
    return;
  }
  if (*value < 0.0f) {
    *value = 0.0f;
  } else if (*value > max_level) {
    *value = max_level;
  }
}

static void
wd_ui_append_level_sample(WireDeckCudaDenoiserUI* ui)
{
  WireDeckLevelSample* sample;
  uint32_t insert_index;
  double now_seconds;

  if (!ui) {
    return;
  }

  now_seconds = (double)g_get_monotonic_time() / 1000000.0;
  wd_ui_trim_level_history(ui, now_seconds - WD_LEVEL_HISTORY_WINDOW_SECONDS);

  insert_index = (ui->level_history_start + ui->level_history_count) % WD_LEVEL_HISTORY_CAPACITY;
  if (ui->level_history_count == WD_LEVEL_HISTORY_CAPACITY) {
    ui->level_history_start = (ui->level_history_start + 1u) % WD_LEVEL_HISTORY_CAPACITY;
    insert_index = (ui->level_history_start + ui->level_history_count - 1u) % WD_LEVEL_HISTORY_CAPACITY;
  } else {
    ++ui->level_history_count;
  }

  sample = &ui->level_history[insert_index];
  sample->timestamp_seconds = now_seconds;
  sample->input_level = ui->input_level_value;
  sample->output_level = ui->output_level_value;
  sample->suppressed_noise_level = ui->suppressed_noise_level_value;
  sample->voice_preservation_level = ui->voice_preservation_level_value;
}

static gboolean
wd_ui_refresh_tick(gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;

  if (!ui || !ui->widgets_alive) {
    return FALSE;
  }

  wd_ui_append_level_sample(ui);
  wd_ui_refresh_runtime_debug(ui);
  return TRUE;
}

static gboolean
wd_ui_render_level_history(GtkWidget* widget, cairo_t* cr, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  double now_seconds;
  double cutoff_seconds;
  double width;
  double height;
  double graph_left = 52.0;
  double graph_right;
  double graph_top = 14.0;
  double graph_bottom;
  double graph_width;
  double graph_height;
  double max_level = 1e-6;
  uint32_t index;

  if (!ui) {
    return FALSE;
  }

  width = (double)widget->allocation.width;
  height = (double)widget->allocation.height;
  graph_right = width - 14.0;
  graph_bottom = height - 26.0;
  graph_width = graph_right - graph_left;
  graph_height = graph_bottom - graph_top;

  cairo_set_source_rgb(cr, 0.06, 0.07, 0.09);
  cairo_paint(cr);

  if (graph_width <= 0.0 || graph_height <= 0.0) {
    return FALSE;
  }

  now_seconds = (double)g_get_monotonic_time() / 1000000.0;
  cutoff_seconds = now_seconds - WD_LEVEL_HISTORY_WINDOW_SECONDS;
  wd_ui_trim_level_history(ui, cutoff_seconds);

  for (index = 0; index < ui->level_history_count; ++index) {
    const WireDeckLevelSample* sample = &ui->level_history[(ui->level_history_start + index) % WD_LEVEL_HISTORY_CAPACITY];
    if ((double)sample->input_level > max_level) {
      max_level = sample->input_level;
    }
    if ((double)sample->output_level > max_level) {
      max_level = sample->output_level;
    }
    if ((double)sample->suppressed_noise_level > max_level) {
      max_level = sample->suppressed_noise_level;
    }
    if ((double)sample->voice_preservation_level > max_level) {
      max_level = sample->voice_preservation_level;
    }
  }
  if (max_level < 0.01) {
    max_level = 0.01;
  }

  cairo_set_line_width(cr, 1.0);
  cairo_set_source_rgb(cr, 0.20, 0.22, 0.25);
  for (index = 0; index <= 6; ++index) {
    double x = graph_left + ((double)index / 6.0) * graph_width;
    cairo_move_to(cr, x, graph_top);
    cairo_line_to(cr, x, graph_bottom);
  }
  for (index = 0; index <= 5; ++index) {
    double y = graph_top + ((double)index / 5.0) * graph_height;
    cairo_move_to(cr, graph_left, y);
    cairo_line_to(cr, graph_right, y);
  }
  cairo_stroke(cr);

  cairo_set_source_rgb(cr, 0.70, 0.72, 0.74);
  cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size(cr, 11.0);
  cairo_move_to(cr, graph_left, height - 8.0);
  cairo_show_text(cr, "5s");
  cairo_move_to(cr, graph_right - 22.0, height - 8.0);
  cairo_show_text(cr, "0s");

  {
    char label[32];
    snprintf(label, sizeof(label), "%.2f", max_level);
    cairo_move_to(cr, 8.0, graph_top + 4.0);
    cairo_show_text(cr, label);
    cairo_move_to(cr, 8.0, graph_bottom + 4.0);
    cairo_show_text(cr, "0.00");
  }

  cairo_rectangle(cr, graph_left, graph_top, graph_width, graph_height);
  cairo_clip(cr);

  if (ui->level_history_count > 0) {
    for (index = 0; index < ui->level_history_count; ++index) {
      const WireDeckLevelSample* sample = &ui->level_history[(ui->level_history_start + index) % WD_LEVEL_HISTORY_CAPACITY];
      double age_seconds = now_seconds - sample->timestamp_seconds;
      double x = graph_right - (age_seconds / WD_LEVEL_HISTORY_WINDOW_SECONDS) * graph_width;
      float level = sample->input_level;
      double input_y;
      wd_ui_clamp_level(&level, (float)max_level);
      input_y = graph_bottom - (level / max_level) * graph_height;
      if (index == 0) {
        cairo_move_to(cr, x, input_y);
      } else {
        cairo_line_to(cr, x, input_y);
      }
    }
    cairo_set_source_rgb(cr, 0.16, 0.71, 0.95);
    cairo_set_line_width(cr, 2.0);
    cairo_stroke(cr);

    for (index = 0; index < ui->level_history_count; ++index) {
      const WireDeckLevelSample* sample = &ui->level_history[(ui->level_history_start + index) % WD_LEVEL_HISTORY_CAPACITY];
      double age_seconds = now_seconds - sample->timestamp_seconds;
      double x = graph_right - (age_seconds / WD_LEVEL_HISTORY_WINDOW_SECONDS) * graph_width;
      float level = sample->output_level;
      double output_y;
      wd_ui_clamp_level(&level, (float)max_level);
      output_y = graph_bottom - (level / max_level) * graph_height;
      if (index == 0) {
        cairo_move_to(cr, x, output_y);
      } else {
        cairo_line_to(cr, x, output_y);
      }
    }
    cairo_set_source_rgb(cr, 0.98, 0.60, 0.20);
    cairo_set_line_width(cr, 2.0);
    cairo_stroke(cr);

    for (index = 0; index < ui->level_history_count; ++index) {
      const WireDeckLevelSample* sample = &ui->level_history[(ui->level_history_start + index) % WD_LEVEL_HISTORY_CAPACITY];
      double age_seconds = now_seconds - sample->timestamp_seconds;
      double x = graph_right - (age_seconds / WD_LEVEL_HISTORY_WINDOW_SECONDS) * graph_width;
      float level = sample->suppressed_noise_level;
      double suppressed_y;
      wd_ui_clamp_level(&level, (float)max_level);
      suppressed_y = graph_bottom - (level / max_level) * graph_height;
      if (index == 0) {
        cairo_move_to(cr, x, suppressed_y);
      } else {
        cairo_line_to(cr, x, suppressed_y);
      }
    }
    cairo_set_source_rgb(cr, 0.86, 0.28, 0.23);
    cairo_set_line_width(cr, 1.8);
    cairo_stroke(cr);

    for (index = 0; index < ui->level_history_count; ++index) {
      const WireDeckLevelSample* sample = &ui->level_history[(ui->level_history_start + index) % WD_LEVEL_HISTORY_CAPACITY];
      double age_seconds = now_seconds - sample->timestamp_seconds;
      double x = graph_right - (age_seconds / WD_LEVEL_HISTORY_WINDOW_SECONDS) * graph_width;
      float level = sample->voice_preservation_level;
      double voice_y;
      wd_ui_clamp_level(&level, (float)max_level);
      voice_y = graph_bottom - (level / max_level) * graph_height;
      if (index == 0) {
        cairo_move_to(cr, x, voice_y);
      } else {
        cairo_line_to(cr, x, voice_y);
      }
    }
    cairo_set_source_rgb(cr, 0.36, 0.82, 0.43);
    cairo_set_line_width(cr, 1.8);
    cairo_stroke(cr);
  }

  cairo_reset_clip(cr);

  cairo_set_source_rgb(cr, 0.16, 0.71, 0.95);
  cairo_rectangle(cr, graph_left, 4.0, 14.0, 3.0);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0.88, 0.89, 0.91);
  cairo_move_to(cr, graph_left + 20.0, 9.0);
  cairo_show_text(cr, "Input");

  cairo_set_source_rgb(cr, 0.98, 0.60, 0.20);
  cairo_rectangle(cr, graph_left + 76.0, 4.0, 14.0, 3.0);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0.88, 0.89, 0.91);
  cairo_move_to(cr, graph_left + 96.0, 9.0);
  cairo_show_text(cr, "Output");

  cairo_set_source_rgb(cr, 0.86, 0.28, 0.23);
  cairo_rectangle(cr, graph_left + 156.0, 4.0, 14.0, 3.0);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0.88, 0.89, 0.91);
  cairo_move_to(cr, graph_left + 176.0, 9.0);
  cairo_show_text(cr, "Suppression");

  cairo_set_source_rgb(cr, 0.36, 0.82, 0.43);
  cairo_rectangle(cr, graph_left + 262.0, 4.0, 14.0, 3.0);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0.88, 0.89, 0.91);
  cairo_move_to(cr, graph_left + 282.0, 9.0);
  cairo_show_text(cr, "Mask Keep");

  return FALSE;
}

static gboolean
wd_ui_expose_level_history(GtkWidget* widget, GdkEventExpose* event, gpointer data)
{
  cairo_t* cr;
  (void)event;

  if (!widget || !widget->window) {
    return FALSE;
  }

  cr = gdk_cairo_create(widget->window);
  if (!cr) {
    return FALSE;
  }

  wd_ui_render_level_history(widget, cr, data);
  cairo_destroy(cr);
  return FALSE;
}

static void
wd_ui_refresh_status(WireDeckCudaDenoiserUI* ui, int status_code)
{
  char status_text[512];

  if (!ui || !ui->widgets_alive || !ui->status_label || !ui->cuda_label) {
    return;
  }

  snprintf(status_text, sizeof(status_text), "Status: %s", wd_status_code_label(status_code));
  gtk_label_set_text(GTK_LABEL(ui->status_label), status_text);

  if (ui->cuda_info.available) {
    char cuda_text[512];
    snprintf(cuda_text, sizeof(cuda_text), "CUDA devices: %d", ui->cuda_info.device_count);
    gtk_label_set_text(GTK_LABEL(ui->cuda_label), cuda_text);
  } else {
    gtk_label_set_text(GTK_LABEL(ui->cuda_label), ui->cuda_info.error_message[0] ? ui->cuda_info.error_message : "CUDA unavailable");
  }
}

static void
wd_ui_refresh_model_info(WireDeckCudaDenoiserUI* ui)
{
  char info[512];
  char error_message[256];

  if (!ui || !ui->widgets_alive || !ui->model_info_label) {
    return;
  }

  if (ui->model_index_value < 0 || ui->model_index_value >= ui->models.count) {
    gtk_label_set_text(GTK_LABEL(ui->model_info_label), "Model info: no model selected");
    return;
  }

  memset(&ui->selected_metadata, 0, sizeof(ui->selected_metadata));
  if (!wd_load_wdgp_metadata(ui->config.models_dir, ui->models.names[ui->model_index_value], &ui->selected_metadata, error_message, sizeof(error_message))) {
    snprintf(info, sizeof(info), "Model info: %s", error_message[0] ? error_message : "unavailable");
    gtk_label_set_text(GTK_LABEL(ui->model_info_label), info);
    return;
  }

  snprintf(
    info,
    sizeof(info),
    "Model info: %s | %d bands | %d ch | %d hidden | %d blocks | lookahead %d | %d tensors",
    ui->selected_metadata.model_name[0] ? ui->selected_metadata.model_name : "WDGP",
    ui->selected_metadata.bands,
    ui->selected_metadata.channels,
    ui->selected_metadata.hidden_channels,
    ui->selected_metadata.residual_blocks,
    ui->selected_metadata.lookahead_frames,
    ui->selected_metadata.tensor_count);
  gtk_label_set_text(GTK_LABEL(ui->model_info_label), info);
}

static void
wd_ui_refresh_runtime_debug(WireDeckCudaDenoiserUI* ui)
{
  char text[256];

  if (!ui || !ui->widgets_alive) {
    return;
  }

  if (ui->level_history_caption) {
    snprintf(
      text,
      sizeof(text),
      "Levels (60s): input %.6f | output %.6f | suppression_est %.6f | mask_keep %.6f",
      ui->input_level_value,
      ui->output_level_value,
      ui->suppressed_noise_level_value,
      ui->voice_preservation_level_value);
    gtk_label_set_text(GTK_LABEL(ui->level_history_caption), text);
  }
  if (ui->level_history_area) {
    gtk_widget_queue_draw(ui->level_history_area);
  }
  if (ui->model_loaded_label) {
    snprintf(text, sizeof(text), "Model loaded: %s", ui->model_loaded_value >= 0.5f ? "yes" : "no");
    gtk_label_set_text(GTK_LABEL(ui->model_loaded_label), text);
  }
  if (ui->runtime_phase_label) {
    snprintf(text, sizeof(text), "Runtime: %s", wd_ui_runtime_phase_label((int)(ui->runtime_phase_value + 0.5f)));
    gtk_label_set_text(GTK_LABEL(ui->runtime_phase_label), text);
  }
}

static void
wd_ui_save_config(WireDeckCudaDenoiserUI* ui)
{
  char error_message[256];
  if (!ui) {
    return;
  }
  wd_config_save(&ui->config, error_message, sizeof(error_message));
}

static void
wd_ui_populate_models(WireDeckCudaDenoiserUI* ui)
{
  int index;
  int resolved_index;

  if (!ui || !ui->widgets_alive || !ui->model_combo) {
    return;
  }

  ui->updating = 1;
  wd_ui_clear_combo_box_text(ui->model_combo);
  for (index = 0; index < ui->models.count; ++index) {
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(ui->model_combo), ui->models.names[index]);
  }

  resolved_index = wd_find_model_index(&ui->models, ui->config.selected_model);
  if (resolved_index < 0 && ui->models.count > 0) {
    resolved_index = 0;
    snprintf(ui->config.selected_model, sizeof(ui->config.selected_model), "%s", ui->models.names[0]);
    wd_ui_save_config(ui);
  }

  ui->model_index_value = resolved_index;
  if (resolved_index >= 0) {
    gtk_combo_box_set_active(GTK_COMBO_BOX(ui->model_combo), resolved_index);
  }
  wd_ui_refresh_model_info(ui);
  ui->updating = 0;
}

static void
wd_ui_reload_models(WireDeckCudaDenoiserUI* ui)
{
  char error_message[256];
  if (!ui) {
    return;
  }
  wd_free_model_scan_result(&ui->models);
  wd_scan_models(ui->config.models_dir, &ui->models, error_message, sizeof(error_message));
  wd_ui_populate_models(ui);
}

static void
wd_ui_populate_gpus(WireDeckCudaDenoiserUI* ui)
{
  int index;
  if (!ui || !ui->widgets_alive || !ui->gpu_combo) {
    return;
  }

  ui->updating = 1;
  wd_ui_clear_combo_box_text(ui->gpu_combo);

  if (!ui->cuda_info.available || ui->cuda_info.device_count <= 0) {
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(ui->gpu_combo), "No CUDA devices");
    gtk_combo_box_set_active(GTK_COMBO_BOX(ui->gpu_combo), 0);
    gtk_widget_set_sensitive(ui->gpu_combo, FALSE);
    ui->updating = 0;
    return;
  }

  gtk_widget_set_sensitive(ui->gpu_combo, TRUE);
  for (index = 0; index < ui->cuda_info.device_count; ++index) {
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(ui->gpu_combo), ui->cuda_info.device_names[index]);
  }

  if (ui->gpu_index_value < 0) {
    ui->gpu_index_value = 0;
  }
  if (ui->gpu_index_value >= ui->cuda_info.device_count) {
    ui->gpu_index_value = ui->cuda_info.device_count - 1;
  }
  gtk_combo_box_set_active(GTK_COMBO_BOX(ui->gpu_combo), ui->gpu_index_value);
  ui->updating = 0;
}

static void
wd_ui_on_folder_changed(GtkFileChooserButton* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  char* path;
  if (!ui || ui->updating) {
    return;
  }

  path = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(widget));
  if (!path) {
    return;
  }

  snprintf(ui->config.models_dir, sizeof(ui->config.models_dir), "%s", path);
  g_free(path);
  wd_ui_save_config(ui);
  wd_ui_reload_models(ui);
}

static void
wd_ui_on_model_changed(GtkComboBox* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  int active;
  if (!ui || ui->updating) {
    return;
  }

  active = gtk_combo_box_get_active(widget);
  if (active < 0 || active >= ui->models.count) {
    return;
  }

  ui->model_index_value = active;
  snprintf(ui->config.selected_model, sizeof(ui->config.selected_model), "%s", ui->models.names[active]);
  wd_ui_save_config(ui);
  wd_ui_refresh_model_info(ui);
  wd_ui_write_control(ui, WD_PORT_MODEL_INDEX, (float)active);
}

static void
wd_ui_on_gpu_changed(GtkComboBox* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  int active;
  if (!ui || ui->updating) {
    return;
  }

  active = gtk_combo_box_get_active(widget);
  if (active < 0) {
    return;
  }

  ui->gpu_index_value = active;
  wd_ui_write_control(ui, WD_PORT_GPU_INDEX, (float)active);
}

static void
wd_ui_on_threshold_changed(GtkRange* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  if (!ui || ui->updating) {
    return;
  }

  ui->threshold_value = (float)gtk_range_get_value(widget);
  wd_ui_write_control(ui, WD_PORT_THRESHOLD, ui->threshold_value);
}

static void
wd_ui_on_buffer_ms_changed(GtkRange* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  if (!ui || ui->updating) {
    return;
  }
  ui->buffer_ms_value = (float)gtk_range_get_value(widget);
  wd_ui_write_control(ui, WD_PORT_BUFFER_MS, ui->buffer_ms_value);
}

static void
wd_ui_on_mix_changed(GtkRange* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  if (!ui || ui->updating) {
    return;
  }
  ui->mix_value = (float)gtk_range_get_value(widget);
  wd_ui_write_control(ui, WD_PORT_MIX, ui->mix_value);
}

static void
wd_ui_on_output_gain_changed(GtkRange* widget, gpointer data)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)data;
  if (!ui || ui->updating) {
    return;
  }
  ui->output_gain_db_value = (float)gtk_range_get_value(widget);
  wd_ui_write_control(ui, WD_PORT_OUTPUT_GAIN_DB, ui->output_gain_db_value);
}

static void
wd_ui_sync_initial_state(WireDeckCudaDenoiserUI* ui)
{
  int initial_status = WD_STATUS_CUDA_UNAVAILABLE;

  if (!ui) {
    return;
  }

  if (ui->models.count > 0 && ui->cuda_info.available) {
    int resolved_index = wd_find_model_index(&ui->models, ui->config.selected_model);
    if (resolved_index < 0) {
      resolved_index = 0;
    }
    if (resolved_index >= 0 && resolved_index < ui->models.count) {
      initial_status = ui->models.is_wdgp[resolved_index] ? WD_STATUS_RUNTIME_NOT_IMPLEMENTED : WD_STATUS_MODEL_FORMAT_UNSUPPORTED;
    }
  } else if (ui->models.count == 0) {
    initial_status = WD_STATUS_NO_MODELS;
  }

  wd_ui_refresh_status(ui, initial_status);
}

static LV2UI_Handle
wd_ui_instantiate(const struct LV2UI_Descriptor* descriptor,
                  const char* plugin_uri,
                  const char* bundle_path,
                  LV2UI_Write_Function write_function,
                  LV2UI_Controller controller,
                  LV2UI_Widget* widget,
                  const LV2_Feature* const* features)
{
  WireDeckCudaDenoiserUI* ui;
  GtkWidget* content;
  GtkWidget* folder_label;
  GtkWidget* model_label;
  GtkWidget* gpu_label;
  GtkWidget* threshold_label;
  GtkWidget* buffer_ms_label;
  GtkWidget* mix_label;
  GtkWidget* output_gain_label;
  GtkWidget* diagnostics_box;
  GtkWidget* level_frame;
  char error_message[256];
  (void)descriptor;
  (void)bundle_path;
  (void)features;

  if (strcmp(plugin_uri, WIREDECK_CUDA_DENOISER_URI) != 0) {
    return NULL;
  }

  ui = (WireDeckCudaDenoiserUI*)calloc(1, sizeof(WireDeckCudaDenoiserUI));
  if (!ui) {
    return NULL;
  }

  ui->write = write_function;
  ui->controller = controller;
  ui->threshold_value = 0.5f;
  ui->buffer_ms_value = 12.0f;
  ui->mix_value = 1.0f;
  ui->output_gain_db_value = 0.0f;
  ui->input_level_value = 0.0f;
  ui->output_level_value = 0.0f;
  ui->suppressed_noise_level_value = 0.0f;
  ui->voice_preservation_level_value = 0.0f;
  ui->model_loaded_value = 0.0f;
  ui->runtime_phase_value = (float)WD_RUNTIME_IDLE;
  ui->gpu_index_value = -1;
  ui->model_index_value = -1;
  ui->widgets_alive = 1;

  wd_config_init_defaults(&ui->config);
  wd_config_load(&ui->config, error_message, sizeof(error_message));
  wd_cuda_probe(&ui->cuda_info);
  wd_scan_models(ui->config.models_dir, &ui->models, error_message, sizeof(error_message));

  ui->root = gtk_vbox_new(FALSE, 10);
  gtk_container_set_border_width(GTK_CONTAINER(ui->root), 12);
  g_signal_connect(ui->root, "destroy", G_CALLBACK(wd_ui_on_root_destroy), ui);

  ui->cuda_label = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->cuda_label), 0.0f, 0.5f);
  gtk_box_pack_start(GTK_BOX(ui->root), ui->cuda_label, FALSE, FALSE, 0);

  ui->status_label = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->status_label), 0.0f, 0.5f);
  gtk_box_pack_start(GTK_BOX(ui->root), ui->status_label, FALSE, FALSE, 0);

  content = gtk_table_new(7, 2, FALSE);
  gtk_table_set_row_spacings(GTK_TABLE(content), 8);
  gtk_table_set_col_spacings(GTK_TABLE(content), 10);
  gtk_box_pack_start(GTK_BOX(ui->root), content, FALSE, FALSE, 0);

  folder_label = gtk_label_new("Models folder");
  gtk_misc_set_alignment(GTK_MISC(folder_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), folder_label, 0, 1, 0, 1, GTK_FILL, GTK_FILL, 0, 0);

  ui->folder_button = gtk_file_chooser_button_new("Select models folder", GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
  gtk_table_attach(GTK_TABLE(content), ui->folder_button, 1, 2, 0, 1, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  model_label = gtk_label_new("Model");
  gtk_misc_set_alignment(GTK_MISC(model_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), model_label, 0, 1, 1, 2, GTK_FILL, GTK_FILL, 0, 0);

  ui->model_combo = gtk_combo_box_text_new();
  gtk_table_attach(GTK_TABLE(content), ui->model_combo, 1, 2, 1, 2, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  gpu_label = gtk_label_new("CUDA device");
  gtk_misc_set_alignment(GTK_MISC(gpu_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), gpu_label, 0, 1, 2, 3, GTK_FILL, GTK_FILL, 0, 0);

  ui->gpu_combo = gtk_combo_box_text_new();
  gtk_table_attach(GTK_TABLE(content), ui->gpu_combo, 1, 2, 2, 3, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  threshold_label = gtk_label_new("Reduction");
  gtk_misc_set_alignment(GTK_MISC(threshold_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), threshold_label, 0, 1, 3, 4, GTK_FILL, GTK_FILL, 0, 0);

  ui->threshold_scale = gtk_hscale_new_with_range(0.0, 1.0, 0.01);
  gtk_range_set_value(GTK_RANGE(ui->threshold_scale), ui->threshold_value);
  gtk_scale_set_digits(GTK_SCALE(ui->threshold_scale), 2);
  gtk_table_attach(GTK_TABLE(content), ui->threshold_scale, 1, 2, 3, 4, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  buffer_ms_label = gtk_label_new("Output delay (ms)");
  gtk_misc_set_alignment(GTK_MISC(buffer_ms_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), buffer_ms_label, 0, 1, 4, 5, GTK_FILL, GTK_FILL, 0, 0);

  ui->buffer_ms_scale = gtk_hscale_new_with_range(0.0, 80.0, 1.0);
  gtk_range_set_value(GTK_RANGE(ui->buffer_ms_scale), ui->buffer_ms_value);
  gtk_scale_set_digits(GTK_SCALE(ui->buffer_ms_scale), 0);
  gtk_table_attach(GTK_TABLE(content), ui->buffer_ms_scale, 1, 2, 4, 5, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  mix_label = gtk_label_new("Mix");
  gtk_misc_set_alignment(GTK_MISC(mix_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), mix_label, 0, 1, 5, 6, GTK_FILL, GTK_FILL, 0, 0);

  ui->mix_scale = gtk_hscale_new_with_range(0.0, 1.0, 0.01);
  gtk_range_set_value(GTK_RANGE(ui->mix_scale), ui->mix_value);
  gtk_scale_set_digits(GTK_SCALE(ui->mix_scale), 2);
  gtk_table_attach(GTK_TABLE(content), ui->mix_scale, 1, 2, 5, 6, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  output_gain_label = gtk_label_new("Output gain (dB)");
  gtk_misc_set_alignment(GTK_MISC(output_gain_label), 0.0f, 0.5f);
  gtk_table_attach(GTK_TABLE(content), output_gain_label, 0, 1, 6, 7, GTK_FILL, GTK_FILL, 0, 0);

  ui->output_gain_scale = gtk_hscale_new_with_range(-18.0, 18.0, 0.5);
  gtk_range_set_value(GTK_RANGE(ui->output_gain_scale), ui->output_gain_db_value);
  gtk_scale_set_digits(GTK_SCALE(ui->output_gain_scale), 1);
  gtk_table_attach(GTK_TABLE(content), ui->output_gain_scale, 1, 2, 6, 7, GTK_EXPAND | GTK_FILL, GTK_FILL, 0, 0);

  ui->model_info_label = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->model_info_label), 0.0f, 0.5f);
  gtk_label_set_line_wrap(GTK_LABEL(ui->model_info_label), TRUE);
  gtk_box_pack_start(GTK_BOX(ui->root), ui->model_info_label, FALSE, FALSE, 0);

  diagnostics_box = gtk_vbox_new(FALSE, 4);
  gtk_box_pack_start(GTK_BOX(ui->root), diagnostics_box, FALSE, FALSE, 0);

  ui->level_history_caption = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->level_history_caption), 0.0f, 0.5f);
  gtk_box_pack_start(GTK_BOX(diagnostics_box), ui->level_history_caption, FALSE, FALSE, 0);

  level_frame = gtk_frame_new(NULL);
  gtk_frame_set_shadow_type(GTK_FRAME(level_frame), GTK_SHADOW_IN);
  gtk_box_pack_start(GTK_BOX(diagnostics_box), level_frame, FALSE, FALSE, 0);

  ui->level_history_area = gtk_drawing_area_new();
  gtk_widget_set_size_request(ui->level_history_area, 420, 180);
  gtk_container_add(GTK_CONTAINER(level_frame), ui->level_history_area);
  g_signal_connect(ui->level_history_area, "expose-event", G_CALLBACK(wd_ui_expose_level_history), ui);

  ui->model_loaded_label = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->model_loaded_label), 0.0f, 0.5f);
  gtk_box_pack_start(GTK_BOX(diagnostics_box), ui->model_loaded_label, FALSE, FALSE, 0);

  ui->runtime_phase_label = gtk_label_new("");
  gtk_misc_set_alignment(GTK_MISC(ui->runtime_phase_label), 0.0f, 0.5f);
  gtk_box_pack_start(GTK_BOX(diagnostics_box), ui->runtime_phase_label, FALSE, FALSE, 0);

  if (!wd_expand_home_path(ui->config.models_dir, error_message, sizeof(error_message))) {
    error_message[0] = '\0';
  }
  if (error_message[0] != '\0') {
    gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(ui->folder_button), error_message);
  }

  wd_ui_populate_models(ui);
  wd_ui_populate_gpus(ui);
  wd_ui_refresh_status(ui, ui->cuda_info.available ? WD_STATUS_RUNTIME_NOT_IMPLEMENTED : WD_STATUS_CUDA_UNAVAILABLE);
  wd_ui_refresh_model_info(ui);
  wd_ui_sync_initial_state(ui);
  wd_ui_refresh_runtime_debug(ui);
  ui->refresh_timer_id = g_timeout_add(50, wd_ui_refresh_tick, ui);

  g_signal_connect(ui->folder_button, "selection-changed", G_CALLBACK(wd_ui_on_folder_changed), ui);
  g_signal_connect(ui->model_combo, "changed", G_CALLBACK(wd_ui_on_model_changed), ui);
  g_signal_connect(ui->gpu_combo, "changed", G_CALLBACK(wd_ui_on_gpu_changed), ui);
  g_signal_connect(ui->threshold_scale, "value-changed", G_CALLBACK(wd_ui_on_threshold_changed), ui);
  g_signal_connect(ui->buffer_ms_scale, "value-changed", G_CALLBACK(wd_ui_on_buffer_ms_changed), ui);
  g_signal_connect(ui->mix_scale, "value-changed", G_CALLBACK(wd_ui_on_mix_changed), ui);
  g_signal_connect(ui->output_gain_scale, "value-changed", G_CALLBACK(wd_ui_on_output_gain_changed), ui);

  *widget = ui->root;
  return (LV2UI_Handle)ui;
}

static void
wd_ui_cleanup(LV2UI_Handle handle)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)handle;
  if (!ui) {
    return;
  }
  ui->widgets_alive = 0;
  if (ui->refresh_timer_id != 0u) {
    g_source_remove(ui->refresh_timer_id);
    ui->refresh_timer_id = 0u;
  }
  wd_free_model_scan_result(&ui->models);
  free(ui);
}

static void
wd_ui_port_event(LV2UI_Handle handle, uint32_t port_index, uint32_t buffer_size, uint32_t format, const void* buffer)
{
  WireDeckCudaDenoiserUI* ui = (WireDeckCudaDenoiserUI*)handle;
  float value;
  (void)buffer_size;

  if (!ui || !ui->widgets_alive || !buffer || format != 0) {
    return;
  }

  value = *(const float*)buffer;
  ui->updating = 1;
  switch ((WireDeckCudaDenoiserPortIndex)port_index) {
  case WD_PORT_THRESHOLD:
    ui->threshold_value = value;
    gtk_range_set_value(GTK_RANGE(ui->threshold_scale), value);
    break;
  case WD_PORT_BUFFER_MS:
    ui->buffer_ms_value = value;
    gtk_range_set_value(GTK_RANGE(ui->buffer_ms_scale), value);
    break;
  case WD_PORT_MIX:
    ui->mix_value = value;
    gtk_range_set_value(GTK_RANGE(ui->mix_scale), value);
    break;
  case WD_PORT_OUTPUT_GAIN_DB:
    ui->output_gain_db_value = value;
    gtk_range_set_value(GTK_RANGE(ui->output_gain_scale), value);
    break;
  case WD_PORT_GPU_INDEX:
    ui->gpu_index_value = (int)(value + 0.5f);
    gtk_combo_box_set_active(GTK_COMBO_BOX(ui->gpu_combo), ui->gpu_index_value);
    break;
  case WD_PORT_MODEL_INDEX:
    ui->model_index_value = (int)(value + 0.5f);
    gtk_combo_box_set_active(GTK_COMBO_BOX(ui->model_combo), ui->model_index_value);
    if (ui->model_index_value >= 0 && ui->model_index_value < ui->models.count) {
      snprintf(ui->config.selected_model, sizeof(ui->config.selected_model), "%s", ui->models.names[ui->model_index_value]);
      wd_ui_save_config(ui);
    }
    break;
  case WD_PORT_STATUS_CODE:
    wd_ui_refresh_status(ui, (int)(value + 0.5f));
    wd_ui_refresh_model_info(ui);
    break;
  case WD_PORT_INPUT_LEVEL:
    ui->input_level_value = value;
    wd_ui_append_level_sample(ui);
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_OUTPUT_LEVEL:
    ui->output_level_value = value;
    wd_ui_append_level_sample(ui);
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_SUPPRESSED_NOISE_LEVEL:
    ui->suppressed_noise_level_value = value;
    wd_ui_append_level_sample(ui);
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_VOICE_PRESERVATION_LEVEL:
    ui->voice_preservation_level_value = value;
    wd_ui_append_level_sample(ui);
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_MODEL_LOADED:
    ui->model_loaded_value = value;
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_RUNTIME_PHASE:
    ui->runtime_phase_value = value;
    wd_ui_refresh_runtime_debug(ui);
    break;
  case WD_PORT_CUDA_AVAILABLE:
  case WD_PORT_GPU_COUNT:
  case WD_PORT_MODEL_COUNT:
  case WD_PORT_ENABLED:
  case WD_PORT_INPUT_L:
  case WD_PORT_INPUT_R:
  case WD_PORT_OUTPUT_L:
  case WD_PORT_OUTPUT_R:
    break;
  }
  ui->updating = 0;
}

static int
wd_ui_idle(LV2UI_Handle handle)
{
  (void)handle;
  return 0;
}

static const void*
wd_ui_extension_data(const char* uri)
{
  static const LV2UI_Idle_Interface idle = { wd_ui_idle };
  if (uri && strcmp(uri, LV2_UI__idleInterface) == 0) {
    return &idle;
  }
  return NULL;
}

static const LV2UI_Descriptor wd_ui_descriptor = {
  WIREDECK_CUDA_DENOISER_UI_URI,
  wd_ui_instantiate,
  wd_ui_cleanup,
  wd_ui_port_event,
  wd_ui_extension_data,
};

LV2_SYMBOL_EXPORT
const LV2UI_Descriptor*
lv2ui_descriptor(uint32_t index)
{
  return index == 0 ? &wd_ui_descriptor : NULL;
}
