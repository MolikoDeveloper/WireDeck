from __future__ import annotations

import json
import shutil
import tarfile
import tempfile
import zipfile
from pathlib import Path

import subprocess
from tqdm import tqdm


AUDIO_SUFFIXES = {".wav", ".flac", ".mp3", ".ogg", ".m4a", ".opus", ".aac", ".sw"}
ARCHIVE_SUFFIXES = (".zip", ".tar", ".tar.gz", ".tgz")


def is_archive(path: Path) -> bool:
    name = path.name.lower()
    return any(name.endswith(suffix) for suffix in ARCHIVE_SUFFIXES)


def is_audio_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES


def iter_audio_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root] if is_audio_file(root) else []
    return sorted(path for path in root.rglob("*") if is_audio_file(path))


def iter_archives(root: Path) -> list[Path]:
    if root.is_file():
        return [root] if is_archive(root) else []
    return sorted(path for path in root.rglob("*") if path.is_file() and is_archive(path))


def convert_to_training_wav(source: Path, output: Path, ffmpeg_bin: str = "ffmpeg") -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix.lower() == ".sw":
        cmd = [
            ffmpeg_bin,
            "-loglevel",
            "error",
            "-y",
            "-f",
            "s16le",
            "-ac",
            "1",
            "-ar",
            "48000",
            "-i",
            str(source),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "48000",
            "-c:a",
            "pcm_s16le",
            str(output),
        ]
    else:
        cmd = [
            ffmpeg_bin,
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "48000",
            "-c:a",
            "pcm_s16le",
            str(output),
        ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode == 0:
        return
    output.unlink(missing_ok=True)
    stderr = (result.stderr or "").strip()
    stdout = (result.stdout or "").strip()
    details = stderr or stdout or f"ffmpeg exited with code {result.returncode}"
    raise RuntimeError(details)


def normalize_corpus(input_root: Path, output_root: Path, ffmpeg_bin: str = "ffmpeg", limit: int | None = None) -> dict:
    output_root.mkdir(parents=True, exist_ok=True)
    audio_dir = output_root / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    failures_path = output_root / "failed_files.json"

    existing_files = sorted(audio_dir.glob("*.wav"))
    resume_count = len(existing_files)
    counter = resume_count
    failed_records = _load_failed_records(failures_path)
    failed_sources = {record["source"] for record in failed_records}
    if limit is not None and resume_count >= limit:
        return _write_manifest(input_root, output_root, [], resume_count, failed_records)

    archives = iter_archives(input_root)
    direct_audio_files = iter_audio_files(input_root)
    single_input_file = input_root.is_file() and is_audio_file(input_root)
    total_candidates = limit if limit is not None else (len(direct_audio_files) if not archives else None)
    progress = tqdm(
        total=total_candidates,
        initial=min(resume_count, total_candidates) if total_candidates is not None else resume_count,
        unit="file",
        desc="Normalizing",
        dynamic_ncols=True,
    )

    archive_records: list[dict[str, object]] = []
    skipped = 0
    try:
        if direct_audio_files:
            progress.set_postfix_str(input_root.name or str(input_root))
            skip_budget = 0 if single_input_file else skipped_resume_target(resume_count, skipped)
            for path in direct_audio_files:
                if limit is not None and counter >= limit:
                    break
                if skipped < skip_budget:
                    skipped += 1
                    continue
                source_key = str(path.resolve())
                if source_key in failed_sources:
                    progress.update(1)
                    continue
                if single_input_file:
                    existing_match = next(iter(sorted(audio_dir.glob(f"*_{path.stem}.wav"))), None)
                    if existing_match is not None:
                        progress.update(1)
                        continue
                target = audio_dir / f"{counter:06d}_{path.stem}.wav"
                if target.exists():
                    counter += 1
                    progress.update(1)
                    continue
                if _try_convert_file(
                    source=path,
                    source_key=source_key,
                    target=target,
                    ffmpeg_bin=ffmpeg_bin,
                    failed_records=failed_records,
                    failed_sources=failed_sources,
                    failures_path=failures_path,
                    progress=progress,
                ):
                    counter += 1
                progress.update(1)
        if archives:
            for archive in archives:
                if limit is not None and counter >= limit:
                    break
                progress.set_postfix_str(archive.name)
                converted_in_archive, skipped_in_archive = _convert_archive(
                    archive=archive,
                    audio_dir=audio_dir,
                    ffmpeg_bin=ffmpeg_bin,
                    counter=counter,
                    skip_count=skipped_resume_target(resume_count, skipped),
                    limit=limit,
                    progress=progress,
                    failed_records=failed_records,
                    failed_sources=failed_sources,
                    failures_path=failures_path,
                )
                archive_records.append(
                    {
                        "archive": str(archive.resolve()),
                        "converted_files": converted_in_archive,
                    }
                )
                skipped += skipped_in_archive + converted_in_archive
                counter += converted_in_archive
    finally:
        progress.close()

    return _write_manifest(input_root, output_root, archive_records, counter, failed_records)


def skipped_resume_target(resume_count: int, skipped: int) -> int:
    return max(0, resume_count - skipped)


def _convert_archive(
    *,
    archive: Path,
    audio_dir: Path,
    ffmpeg_bin: str,
    counter: int,
    skip_count: int,
    limit: int | None,
    progress: tqdm,
    failed_records: list[dict[str, str]],
    failed_sources: set[str],
    failures_path: Path,
) -> tuple[int, int]:
    converted = 0
    skipped = 0

    if archive.name.lower().endswith(".zip"):
        with zipfile.ZipFile(archive) as handle:
            infos = sorted(
                (
                    info
                    for info in handle.infolist()
                    if (not info.is_dir()) and Path(info.filename).suffix.lower() in AUDIO_SUFFIXES
                ),
                key=lambda info: info.filename,
            )
            for info in infos:
                if limit is not None and (counter + converted) >= limit:
                    break
                if skipped < skip_count:
                    skipped += 1
                    continue
                source_key = f"{archive.resolve()}::{info.filename}"
                if source_key in failed_sources:
                    progress.update(1)
                    continue
                member_name = Path(info.filename).name
                target = audio_dir / f"{counter + converted:06d}_{Path(member_name).stem}.wav"
                if target.exists():
                    converted += 1
                    progress.update(1)
                    continue
                with tempfile.NamedTemporaryFile(prefix="wiredeck-rnnoise-audio-", suffix=Path(member_name).suffix, delete=False) as temp_handle:
                    temp_path = Path(temp_handle.name)
                    try:
                        with handle.open(info) as source:
                            shutil.copyfileobj(source, temp_handle)
                        if _try_convert_file(
                            source=temp_path,
                            source_key=source_key,
                            target=target,
                            ffmpeg_bin=ffmpeg_bin,
                            failed_records=failed_records,
                            failed_sources=failed_sources,
                            failures_path=failures_path,
                            progress=progress,
                        ):
                            converted += 1
                    finally:
                        temp_path.unlink(missing_ok=True)
                progress.update(1)
    else:
        with tarfile.open(archive) as handle:
            members = sorted(
                (
                    member
                    for member in handle.getmembers()
                    if member.isfile() and Path(member.name).suffix.lower() in AUDIO_SUFFIXES
                ),
                key=lambda member: member.name,
            )
            for member in members:
                if limit is not None and (counter + converted) >= limit:
                    break
                if skipped < skip_count:
                    skipped += 1
                    continue
                source_key = f"{archive.resolve()}::{member.name}"
                if source_key in failed_sources:
                    progress.update(1)
                    continue
                member_name = Path(member.name).name
                target = audio_dir / f"{counter + converted:06d}_{Path(member_name).stem}.wav"
                if target.exists():
                    converted += 1
                    progress.update(1)
                    continue
                source = handle.extractfile(member)
                if source is None:
                    continue
                with tempfile.NamedTemporaryFile(prefix="wiredeck-rnnoise-audio-", suffix=Path(member_name).suffix, delete=False) as temp_handle:
                    temp_path = Path(temp_handle.name)
                    try:
                        with source:
                            shutil.copyfileobj(source, temp_handle)
                        if _try_convert_file(
                            source=temp_path,
                            source_key=source_key,
                            target=target,
                            ffmpeg_bin=ffmpeg_bin,
                            failed_records=failed_records,
                            failed_sources=failed_sources,
                            failures_path=failures_path,
                            progress=progress,
                        ):
                            converted += 1
                    finally:
                        temp_path.unlink(missing_ok=True)
                progress.update(1)

    return converted, skipped


def _try_convert_file(
    *,
    source: Path,
    source_key: str,
    target: Path,
    ffmpeg_bin: str,
    failed_records: list[dict[str, str]],
    failed_sources: set[str],
    failures_path: Path,
    progress: tqdm,
) -> bool:
    try:
        convert_to_training_wav(source, target, ffmpeg_bin=ffmpeg_bin)
        return True
    except RuntimeError as exc:
        if source_key not in failed_sources:
            failed_sources.add(source_key)
            failed_records.append({"source": source_key, "error": str(exc)})
            _write_failed_records(failures_path, failed_records)
        progress.write(f"[wiredeck-rnnoise] warning: skipping unreadable audio: {source_key}")
        return False


def _load_failed_records(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    records: list[dict[str, str]] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        source = item.get("source")
        error = item.get("error")
        if isinstance(source, str) and isinstance(error, str):
            records.append({"source": source, "error": error})
    return records


def _write_failed_records(path: Path, failed_records: list[dict[str, str]]) -> None:
    path.write_text(json.dumps(failed_records, indent=2) + "\n", encoding="utf-8")


def _write_manifest(
    input_root: Path,
    output_root: Path,
    archive_records: list[dict[str, object]],
    count: int,
    failed_records: list[dict[str, str]],
) -> dict:
    audio_dir = output_root / "audio"
    normalized_files = [str(path.resolve()) for path in sorted(audio_dir.glob("*.wav"))]
    manifest: dict[str, object] = {
        "input_root": str(input_root.resolve()),
        "output_root": str(output_root.resolve()),
        "archives": archive_records,
        "normalized_files": normalized_files,
        "count": count,
        "failed_files": failed_records,
        "failed_count": len(failed_records),
    }
    manifest_path = output_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest
