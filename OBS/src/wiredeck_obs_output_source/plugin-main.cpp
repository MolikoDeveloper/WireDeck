#include <obs-module.h>
#include <util/platform.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "wiredeck_obs_output_protocol.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("OpenAI")

MODULE_EXPORT const char *obs_module_name(void)
{
	return "WireDeck OBS Output Source";
}

MODULE_EXPORT const char *obs_module_description(void)
{
	return "Receives WireDeck output buses directly over UDP.";
}

namespace {

constexpr const char *kSourceId = "wiredeck_obs_output_source";
constexpr const char *kHostSetting = "host";
constexpr const char *kOutputSetting = "output_id";

#ifdef _WIN32
using socket_handle = SOCKET;
constexpr socket_handle kInvalidSocket = INVALID_SOCKET;
#else
using socket_handle = int;
constexpr socket_handle kInvalidSocket = -1;
#endif

struct OutputEntry {
	std::string id;
	std::string label;
};

struct WireDeckObsSource {
	obs_source_t *source = nullptr;
	std::mutex mutex;
	std::thread worker;
	std::atomic<bool> stop_requested{false};
	std::atomic<uint64_t> settings_generation{1};
	std::string host = "127.0.0.1";
	std::string output_id;
	uint32_t request_counter = 1;
	uint64_t next_audio_timestamp_ns = 0;
	uint64_t audio_packets_received = 0;
	uint64_t audio_frames_received = 0;
	uint64_t audio_packets_lost = 0;
	uint64_t last_audio_log_ns = 0;
	float last_audio_peak = 0.0f;
	uint64_t sender_clock_offset_ns = 0;
	bool have_sender_clock = false;
	uint32_t last_sequence = 0;
	bool have_sequence = false;
	std::vector<float> left_buffer;
	std::vector<float> right_buffer;
	std::vector<float> mono_buffer;
};

static bool ensure_socket_runtime()
{
#ifdef _WIN32
	static std::atomic<bool> initialized{false};
	static std::atomic<bool> ready{false};
	bool expected = false;
	if (initialized.compare_exchange_strong(expected, true)) {
		WSADATA data{};
		if (WSAStartup(MAKEWORD(2, 2), &data) == 0)
			ready.store(true);
	}
	return ready.load();
#else
	return true;
#endif
}

static void close_socket_handle(socket_handle sock)
{
	if (sock == kInvalidSocket)
		return;
#ifdef _WIN32
	closesocket(sock);
#else
	close(sock);
#endif
}

static bool wait_socket_readable(socket_handle sock, int timeout_ms)
{
#ifdef _WIN32
	WSAPOLLFD pfd{};
	pfd.fd = sock;
	pfd.events = POLLRDNORM;
	return WSAPoll(&pfd, 1, timeout_ms) > 0 && (pfd.revents & POLLRDNORM) != 0;
#else
	pollfd pfd{};
	pfd.fd = sock;
	pfd.events = POLLIN;
	return poll(&pfd, 1, timeout_ms) > 0 && (pfd.revents & POLLIN) != 0;
#endif
}

static bool parse_host_ipv4(const std::string &host, sockaddr_in &addr)
{
	std::memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(static_cast<uint16_t>(WD_OBS_CONTROL_PORT));
#ifdef _WIN32
	return InetPtonA(AF_INET, host.c_str(), &addr.sin_addr) == 1;
#else
	return inet_pton(AF_INET, host.c_str(), &addr.sin_addr) == 1;
#endif
}

static std::string read_protocol_string(const char *field, size_t size)
{
	size_t len = 0;
	while (len < size && field[len] != '\0')
		++len;
	return std::string(field, len);
}

static void write_protocol_string(char *field, size_t size, const std::string &value)
{
	std::memset(field, 0, size);
	if (size == 0)
		return;
	const size_t len = value.size() < (size - 1) ? value.size() : (size - 1);
	if (len > 0)
		std::memcpy(field, value.data(), len);
}

static socket_handle create_bound_udp_socket()
{
	if (!ensure_socket_runtime())
		return kInvalidSocket;

	socket_handle sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (sock == kInvalidSocket)
		return kInvalidSocket;

	sockaddr_in local{};
	local.sin_family = AF_INET;
	local.sin_port = htons(0);
	local.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(sock, reinterpret_cast<sockaddr *>(&local), sizeof(local)) != 0) {
		close_socket_handle(sock);
		return kInvalidSocket;
	}

	return sock;
}

static bool send_bytes(socket_handle sock, const sockaddr_in &addr, const uint8_t *data, size_t size)
{
	return sendto(sock, reinterpret_cast<const char *>(data), static_cast<int>(size), 0,
		      reinterpret_cast<const sockaddr *>(&addr), sizeof(addr)) >= 0;
}

static int recv_bytes(socket_handle sock, uint8_t *data, size_t size, sockaddr_in *from)
{
#ifdef _WIN32
	int from_len = sizeof(*from);
#else
	socklen_t from_len = sizeof(*from);
#endif
	return recvfrom(sock, reinterpret_cast<char *>(data), static_cast<int>(size), 0,
			reinterpret_cast<sockaddr *>(from), &from_len);
}

static uint32_t next_request_id(WireDeckObsSource *source)
{
	std::lock_guard<std::mutex> lock(source->mutex);
	uint32_t value = source->request_counter++;
	if (source->request_counter == 0)
		source->request_counter = 1;
	return value;
}

static void copy_settings_snapshot(WireDeckObsSource *source, std::string &host, std::string &output_id)
{
	std::lock_guard<std::mutex> lock(source->mutex);
	host = source->host;
	output_id = source->output_id;
}

static const char *safe_obs_string(obs_data_t *settings, const char *name)
{
	const char *value = obs_data_get_string(settings, name);
	return value != nullptr ? value : "";
}

static const char *populate_output_list_for_host(obs_property_t *property, const std::string &host,
						 const std::string &current_output)
{
	obs_property_list_clear(property);
	if (host.empty()) {
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "Write the WireDeck host IP first.";
	}

	sockaddr_in remote{};
	if (!parse_host_ipv4(host, remote)) {
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "Invalid IPv4 host.";
	}

	socket_handle sock = create_bound_udp_socket();
	if (sock == kInvalidSocket) {
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "Unable to open UDP socket.";
	}

	wd_obs_discover_request request{};
	request.header.magic = WD_OBS_PROTOCOL_MAGIC;
	request.header.version = WD_OBS_PROTOCOL_VERSION;
	request.header.kind = WD_OBS_PACKET_DISCOVER_REQUEST;
	request.header.request_id = static_cast<uint32_t>(os_gettime_ns());
	send_bytes(sock, remote, reinterpret_cast<const uint8_t *>(&request), sizeof(request));

	if (!wait_socket_readable(sock, 350)) {
		close_socket_handle(sock);
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "WireDeck did not answer discovery.";
	}

	uint8_t buffer[sizeof(wd_obs_discover_response)]{};
	sockaddr_in from{};
	const int bytes = recv_bytes(sock, buffer, sizeof(buffer), &from);
	close_socket_handle(sock);
	if (bytes < static_cast<int>(sizeof(wd_obs_packet_header))) {
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "Incomplete discovery response.";
	}

	const auto *response = reinterpret_cast<const wd_obs_discover_response *>(buffer);
	if (response->header.magic != WD_OBS_PROTOCOL_MAGIC ||
	    response->header.version != WD_OBS_PROTOCOL_VERSION ||
	    response->header.kind != WD_OBS_PACKET_DISCOVER_RESPONSE) {
		if (!current_output.empty())
			obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());
		return "Unexpected discovery response.";
	}

	const size_t count = response->output_count < WD_OBS_MAX_OUTPUTS ? response->output_count : WD_OBS_MAX_OUTPUTS;
	bool found_current = false;
	size_t added = 0;
	for (size_t i = 0; i < count; ++i) {
		const std::string id = read_protocol_string(response->outputs[i].id, sizeof(response->outputs[i].id));
		if (id.empty())
			continue;
		const std::string label = read_protocol_string(response->outputs[i].label, sizeof(response->outputs[i].label));
		obs_property_list_add_string(property, label.empty() ? id.c_str() : label.c_str(), id.c_str());
		if (id == current_output)
			found_current = true;
		++added;
	}

	if (!found_current && !current_output.empty())
		obs_property_list_add_string(property, current_output.c_str(), current_output.c_str());

	return added == 0 ? "WireDeck returned no OBS-ready outputs." : nullptr;
}

static void refresh_output_property(obs_properties_t *props, obs_data_t *settings)
{
	if (props == nullptr || settings == nullptr)
		return;

	obs_property_t *output = obs_properties_get(props, kOutputSetting);
	if (output == nullptr)
		return;

	const std::string host = safe_obs_string(settings, kHostSetting);
	const std::string current_output = safe_obs_string(settings, kOutputSetting);
	const char *discovery_error = populate_output_list_for_host(output, host, current_output);
	if (discovery_error != nullptr) {
		const size_t idx = obs_property_list_add_string(output, discovery_error, "");
		obs_property_list_item_disable(output, idx, true);
	}
}

static void reset_audio_clock(WireDeckObsSource *source)
{
	source->next_audio_timestamp_ns = 0;
	source->audio_packets_received = 0;
	source->audio_frames_received = 0;
	source->audio_packets_lost = 0;
	source->last_audio_log_ns = 0;
	source->last_audio_peak = 0.0f;
	source->sender_clock_offset_ns = 0;
	source->have_sender_clock = false;
	source->last_sequence = 0;
	source->have_sequence = false;
}

static void output_audio_packet(WireDeckObsSource *source, const wd_obs_audio_packet_header &header,
				const uint8_t *payload, size_t payload_size)
{
	if (header.codec != WD_OBS_AUDIO_CODEC_PCM_S16LE || header.frames == 0)
		return;

	const size_t channels = header.channels > 0 ? header.channels : WD_OBS_DEFAULT_CHANNELS;
	const size_t sample_count = static_cast<size_t>(header.frames) * channels;
	const size_t expected_bytes = sample_count * sizeof(int16_t);
	if (payload_size < expected_bytes)
		return;

	const auto *samples = reinterpret_cast<const int16_t *>(payload);
	const uint32_t sample_rate = header.sample_rate_hz != 0 ? header.sample_rate_hz : WD_OBS_DEFAULT_SAMPLE_RATE;

	obs_source_audio audio{};
	audio.frames = header.frames;
	audio.samples_per_sec = sample_rate;
	audio.format = AUDIO_FORMAT_FLOAT_PLANAR;
	audio.speakers = channels <= 1 ? SPEAKERS_MONO : SPEAKERS_STEREO;
	float packet_peak = 0.0f;

	if (channels <= 1) {
		source->mono_buffer.resize(header.frames);
		for (size_t i = 0; i < header.frames; ++i) {
			source->mono_buffer[i] = static_cast<float>(samples[i]) / 32768.0f;
			packet_peak = std::max(packet_peak, std::abs(source->mono_buffer[i]));
		}
		audio.data[0] = reinterpret_cast<const uint8_t *>(source->mono_buffer.data());
	} else {
		source->left_buffer.resize(header.frames);
		source->right_buffer.resize(header.frames);
		for (size_t i = 0; i < header.frames; ++i) {
			source->left_buffer[i] = static_cast<float>(samples[i * channels]) / 32768.0f;
			source->right_buffer[i] = static_cast<float>(samples[i * channels + 1]) / 32768.0f;
			packet_peak = std::max(packet_peak, std::abs(source->left_buffer[i]));
			packet_peak = std::max(packet_peak, std::abs(source->right_buffer[i]));
		}
		audio.data[0] = reinterpret_cast<const uint8_t *>(source->left_buffer.data());
		audio.data[1] = reinterpret_cast<const uint8_t *>(source->right_buffer.data());
	}

	const uint64_t now_ns = os_gettime_ns();
	const uint64_t duration_ns = (static_cast<uint64_t>(header.frames) * 1000000000ull) / sample_rate;
	uint64_t mapped_sender_time_ns = now_ns;
	if (header.sender_time_ns != 0) {
		if (!source->have_sender_clock) {
			source->sender_clock_offset_ns =
				now_ns > header.sender_time_ns ? (now_ns - header.sender_time_ns) : 0;
			source->have_sender_clock = true;
		}
		mapped_sender_time_ns = header.sender_time_ns + source->sender_clock_offset_ns;
	}
	if (source->have_sequence && header.sequence != source->last_sequence + 1) {
		const uint32_t lost = header.sequence > source->last_sequence
					      ? (header.sequence - source->last_sequence - 1)
					      : 0;
		source->audio_packets_lost += lost;
	}
	source->last_sequence = header.sequence;
	source->have_sequence = true;
	if (source->next_audio_timestamp_ns == 0 ||
	    mapped_sender_time_ns > source->next_audio_timestamp_ns + 40000000ull ||
	    now_ns > source->next_audio_timestamp_ns + 40000000ull) {
		source->next_audio_timestamp_ns = mapped_sender_time_ns;
	}
	audio.timestamp = source->next_audio_timestamp_ns;
	source->next_audio_timestamp_ns += duration_ns;

	obs_source_output_audio(source->source, &audio);
	source->audio_packets_received += 1;
	source->audio_frames_received += header.frames;
	source->last_audio_peak = packet_peak;
	if (source->last_audio_log_ns == 0 || now_ns - source->last_audio_log_ns >= 1000000000ull) {
		source->last_audio_log_ns = now_ns;
		blog(LOG_INFO,
		     "[wiredeck-obs] audio active: packets=%llu lost=%llu frames=%llu peak=%.3f pending=%s active=%s",
		     static_cast<unsigned long long>(source->audio_packets_received),
		     static_cast<unsigned long long>(source->audio_packets_lost),
		     static_cast<unsigned long long>(source->audio_frames_received), packet_peak,
		     obs_source_audio_pending(source->source) ? "yes" : "no",
		     obs_source_audio_active(source->source) ? "yes" : "no");
	}
}

static void send_goodbye(socket_handle sock, const sockaddr_in &remote, uint32_t stream_id)
{
	if (stream_id == 0)
		return;

	wd_obs_goodbye goodbye{};
	goodbye.header.magic = WD_OBS_PROTOCOL_MAGIC;
	goodbye.header.version = WD_OBS_PROTOCOL_VERSION;
	goodbye.header.kind = WD_OBS_PACKET_GOODBYE;
	goodbye.header.stream_id = stream_id;
	send_bytes(sock, remote, reinterpret_cast<const uint8_t *>(&goodbye), sizeof(goodbye));
}

static bool run_stream_session(WireDeckObsSource *source, const std::string &host, const std::string &output_id,
			       uint64_t generation)
{
	sockaddr_in remote{};
	if (!parse_host_ipv4(host, remote)) {
		blog(LOG_WARNING, "[wiredeck-obs] invalid host '%s'", host.c_str());
		return false;
	}

	socket_handle sock = create_bound_udp_socket();
	if (sock == kInvalidSocket) {
		blog(LOG_WARNING, "[wiredeck-obs] unable to open UDP socket");
		return false;
	}

	const uint32_t request_id = next_request_id(source);
	wd_obs_subscribe_request subscribe{};
	subscribe.header.magic = WD_OBS_PROTOCOL_MAGIC;
	subscribe.header.version = WD_OBS_PROTOCOL_VERSION;
	subscribe.header.kind = WD_OBS_PACKET_SUBSCRIBE_REQUEST;
	subscribe.header.request_id = request_id;
	write_protocol_string(subscribe.client_name, sizeof(subscribe.client_name), "OBS Studio");
	write_protocol_string(subscribe.bus_id, sizeof(subscribe.bus_id), output_id);

	uint64_t last_subscribe_attempt_ns = 0;
	uint64_t last_keepalive_ns = 0;
	uint64_t last_audio_ns = 0;
	uint32_t stream_id = 0;
	bool subscribed = false;
	reset_audio_clock(source);
	blog(LOG_INFO, "[wiredeck-obs] connecting to %s output=%s", host.c_str(), output_id.c_str());

	while (!source->stop_requested.load()) {
		if (source->settings_generation.load() != generation)
			break;

		const uint64_t now_ns = os_gettime_ns();
		if (!subscribed) {
			if (last_subscribe_attempt_ns == 0 || now_ns - last_subscribe_attempt_ns >= 500000000ull) {
				send_bytes(sock, remote, reinterpret_cast<const uint8_t *>(&subscribe), sizeof(subscribe));
				last_subscribe_attempt_ns = now_ns;
				blog(LOG_INFO, "[wiredeck-obs] subscribe request sent: request_id=%u host=%s output=%s", request_id,
				     host.c_str(), output_id.c_str());
			}
		} else if (now_ns - last_keepalive_ns >= 1000000000ull) {
			wd_obs_keepalive keepalive{};
			keepalive.header.magic = WD_OBS_PROTOCOL_MAGIC;
			keepalive.header.version = WD_OBS_PROTOCOL_VERSION;
			keepalive.header.kind = WD_OBS_PACKET_KEEPALIVE;
			keepalive.header.stream_id = stream_id;
			send_bytes(sock, remote, reinterpret_cast<const uint8_t *>(&keepalive), sizeof(keepalive));
			last_keepalive_ns = now_ns;
		}

		if (!wait_socket_readable(sock, subscribed ? 100 : 250)) {
			if (!subscribed && now_ns - last_subscribe_attempt_ns > 1500000000ull) {
				blog(LOG_WARNING, "[wiredeck-obs] subscribe timed out waiting for response");
				close_socket_handle(sock);
				return false;
			}
			if (subscribed && last_audio_ns != 0 && now_ns - last_audio_ns > 2500000000ull) {
				blog(LOG_WARNING, "[wiredeck-obs] audio timeout, reconnecting");
				send_goodbye(sock, remote, stream_id);
				close_socket_handle(sock);
				return false;
			}
			continue;
		}

		constexpr size_t kMaxPacketSize =
			sizeof(wd_obs_subscribe_response) >
					(sizeof(wd_obs_audio_packet_header) + WD_OBS_DEFAULT_FRAMES_PER_PACKET *
									 WD_OBS_DEFAULT_CHANNELS * sizeof(int16_t))
				? sizeof(wd_obs_subscribe_response)
				: (sizeof(wd_obs_audio_packet_header) + WD_OBS_DEFAULT_FRAMES_PER_PACKET *
									 WD_OBS_DEFAULT_CHANNELS * sizeof(int16_t));
		uint8_t buffer[kMaxPacketSize]{};
		sockaddr_in from{};
		const int bytes = recv_bytes(sock, buffer, sizeof(buffer), &from);
		if (bytes < static_cast<int>(sizeof(wd_obs_packet_header)))
			continue;

		const auto *base = reinterpret_cast<const wd_obs_packet_header *>(buffer);
		if (base->magic != WD_OBS_PROTOCOL_MAGIC || base->version != WD_OBS_PROTOCOL_VERSION)
			continue;
		if (base->kind == WD_OBS_PACKET_SUBSCRIBE_RESPONSE) {
			if (bytes < static_cast<int>(sizeof(wd_obs_subscribe_response)))
				continue;
			const auto *response = reinterpret_cast<const wd_obs_subscribe_response *>(buffer);
			if (response->header.request_id != request_id)
				continue;
			if (response->accepted == 0) {
				blog(LOG_WARNING, "[wiredeck-obs] subscribe rejected: %s",
				     read_protocol_string(response->message, sizeof(response->message)).c_str());
				close_socket_handle(sock);
				return false;
			}
			stream_id = response->header.stream_id;
			subscribed = true;
			last_keepalive_ns = now_ns;
			last_audio_ns = now_ns;
			reset_audio_clock(source);
			blog(LOG_INFO, "[wiredeck-obs] subscribed: stream_id=%u bus=%s label=%s rate=%u channels=%u frames=%u",
			     stream_id,
			     read_protocol_string(response->bus_id, sizeof(response->bus_id)).c_str(),
			     read_protocol_string(response->bus_label, sizeof(response->bus_label)).c_str(),
			     response->sample_rate_hz, response->channels, response->frames_per_packet);
			continue;
		}

		if (base->kind != WD_OBS_PACKET_AUDIO || !subscribed)
			continue;

		if (bytes < static_cast<int>(sizeof(wd_obs_audio_packet_header)))
			continue;
		const auto *audio_header = reinterpret_cast<const wd_obs_audio_packet_header *>(buffer);
		if (audio_header->header.stream_id != stream_id)
			continue;

		output_audio_packet(source, *audio_header, buffer + sizeof(wd_obs_audio_packet_header),
				    static_cast<size_t>(bytes) - sizeof(wd_obs_audio_packet_header));
		last_audio_ns = now_ns;
	}

	send_goodbye(sock, remote, stream_id);
	close_socket_handle(sock);
	return true;
}

static void worker_main(WireDeckObsSource *source)
{
	while (!source->stop_requested.load()) {
		std::string host;
		std::string output_id;
		copy_settings_snapshot(source, host, output_id);

		if (host.empty() || output_id.empty()) {
			std::this_thread::sleep_for(std::chrono::milliseconds(250));
			continue;
		}

		const uint64_t generation = source->settings_generation.load();
		const bool clean_exit = run_stream_session(source, host, output_id, generation);
		if (source->stop_requested.load())
			return;
		if (clean_exit && source->settings_generation.load() != generation)
			continue;
		std::this_thread::sleep_for(std::chrono::milliseconds(400));
	}
}

static void start_worker(WireDeckObsSource *source)
{
	source->stop_requested.store(false);
	source->worker = std::thread(worker_main, source);
}

static void stop_worker(WireDeckObsSource *source)
{
	source->stop_requested.store(true);
	if (source->worker.joinable())
		source->worker.join();
}

static void apply_settings(WireDeckObsSource *source, obs_data_t *settings)
{
	std::lock_guard<std::mutex> lock(source->mutex);
	source->host = safe_obs_string(settings, kHostSetting);
	if (source->host.empty())
		source->host = "127.0.0.1";
	source->output_id = safe_obs_string(settings, kOutputSetting);
	source->settings_generation.fetch_add(1);
	blog(LOG_INFO, "[wiredeck-obs] settings applied: host=%s output=%s", source->host.c_str(),
	     source->output_id.empty() ? "(empty)" : source->output_id.c_str());
}

static const char *wiredeck_source_get_name(void *)
{
	return "WireDeck Output (UDP)";
}

static void *wiredeck_source_create(obs_data_t *settings, obs_source_t *source)
{
	auto *state = new WireDeckObsSource{};
	state->source = source;
	apply_settings(state, settings);
	obs_source_set_audio_active(source, true);
	obs_source_set_async_unbuffered(source, true);
	obs_source_set_async_decoupled(source, true);
	start_worker(state);
	return state;
}

static void wiredeck_source_destroy(void *data)
{
	auto *state = static_cast<WireDeckObsSource *>(data);
	if (state == nullptr)
		return;
	stop_worker(state);
	delete state;
}

static void wiredeck_source_update(void *data, obs_data_t *settings)
{
	auto *state = static_cast<WireDeckObsSource *>(data);
	if (state == nullptr)
		return;
	apply_settings(state, settings);
}

static void wiredeck_source_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, kHostSetting, "127.0.0.1");
	obs_data_set_default_string(settings, kOutputSetting, "");
}

static bool refresh_outputs_clicked(obs_properties_t *props, obs_property_t *, void *data)
{
	(void)data;
	obs_data_t *settings = obs_properties_get_param(props)
				       ? reinterpret_cast<obs_data_t *>(obs_properties_get_param(props))
				       : nullptr;
	refresh_output_property(props, settings);
	return true;
}

static bool host_modified(void *data, obs_properties_t *props, obs_property_t *, obs_data_t *settings)
{
	(void)data;
	refresh_output_property(props, settings);
	return true;
}

static obs_properties_t *wiredeck_source_get_properties(void *data)
{
	auto *state = static_cast<WireDeckObsSource *>(data);
	obs_properties_t *props = obs_properties_create();

	obs_property_t *host = obs_properties_add_text(props, kHostSetting, "WireDeck host IP", OBS_TEXT_DEFAULT);
	obs_property_set_modified_callback2(host, host_modified, data);

	obs_property_t *output = obs_properties_add_list(props, kOutputSetting, "WireDeck output",
							 OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);

	std::string current_host = "127.0.0.1";
	std::string current_output;
	if (state != nullptr)
		copy_settings_snapshot(state, current_host, current_output);

	const char *discovery_error = populate_output_list_for_host(output, current_host, current_output);
	if (discovery_error != nullptr) {
		const size_t idx = obs_property_list_add_string(output, discovery_error, "");
		obs_property_list_item_disable(output, idx, true);
	}

	obs_properties_add_button2(props, "refresh_outputs", "Refresh outputs", refresh_outputs_clicked, data);
	return props;
}

static obs_source_info wiredeck_source_info = {};

} // namespace

bool obs_module_load(void)
{
	wiredeck_source_info.id = kSourceId;
	wiredeck_source_info.type = OBS_SOURCE_TYPE_INPUT;
	wiredeck_source_info.output_flags = OBS_SOURCE_AUDIO;
	wiredeck_source_info.get_name = wiredeck_source_get_name;
	wiredeck_source_info.create = wiredeck_source_create;
	wiredeck_source_info.destroy = wiredeck_source_destroy;
	wiredeck_source_info.update = wiredeck_source_update;
	wiredeck_source_info.get_defaults = wiredeck_source_get_defaults;
	wiredeck_source_info.get_properties = wiredeck_source_get_properties;
	obs_register_source(&wiredeck_source_info);
	blog(LOG_INFO, "[wiredeck-obs] loaded WireDeck OBS output source");
	return true;
}
