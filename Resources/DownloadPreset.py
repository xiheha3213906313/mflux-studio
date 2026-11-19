import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import os
from pathlib import Path, PurePosixPath
from threading import Thread
from time import sleep

from huggingface_hub import HfApi, hf_hub_url
from huggingface_hub.file_download import http_get
from huggingface_hub.utils import build_hf_headers, filter_repo_objects


def stop_when_app_closes(parent_pid):
    while os.getppid() == parent_pid:
        sleep(0.5)
    os._exit(1)


def download_file(repo, revision, workspace, entry):
    name, size = entry.rfilename, entry.size
    relative = PurePosixPath(name)
    if relative.is_absolute() or not relative.parts or ".." in relative.parts or size is None or size < 0:
        raise ValueError(f"无效的模型文件信息：{name}")

    output = workspace / "package" / relative
    if output.is_file() and output.stat().st_size == size:
        print(f"已保留 {name}")
        return

    key = hashlib.sha256(name.encode()).hexdigest()
    partial = workspace / "partial" / key
    partial.touch(exist_ok=True)
    with partial.open("r+b", buffering=0) as stream:
        offset = stream.seek(0, os.SEEK_END)
        if offset > size:
            stream.seek(0)
            stream.truncate()
            offset = 0
        print(f"{'续传' if offset else '下载'} {name}（{offset:,}/{size:,} 字节）")
        http_get(
            hf_hub_url(repo, name, revision=revision),
            stream,
            resume_size=offset,
            expected_size=size,
            headers={**build_hf_headers(token=False), "Accept-Encoding": "identity"},
            displayed_filename=name,
        )
        if stream.seek(0, os.SEEK_END) != size:
            raise OSError(f"文件大小不符：{name}")
        if entry.lfs is not None and entry.lfs.sha256:
            stream.seek(0)
            if hashlib.file_digest(stream, "sha256").hexdigest() != entry.lfs.sha256:
                partial.unlink()
                raise OSError(f"校验失败，重新继续时会重下此文件：{name}")

    output.parent.mkdir(parents=True, exist_ok=True)
    partial.replace(output)
    print(f"已完成 {name}")


def download_package(args):
    revision_file = args.workspace / "revision"
    revision = revision_file.read_text().strip() if revision_file.is_file() else None
    info = HfApi().model_info(args.repo, revision=revision, files_metadata=True, token=False, timeout=30)
    if not info.sha or (revision is not None and revision != info.sha):
        raise ValueError("无法确认下载对应的模型版本。")
    if revision is None:
        temporary = revision_file.with_suffix(".tmp")
        temporary.write_text(info.sha)
        temporary.replace(revision_file)

    files = list(filter_repo_objects(
        info.siblings or [], allow_patterns=args.include, key=lambda entry: entry.rfilename
    ))
    if not files:
        raise ValueError("模型仓库没有匹配的文件。")

    (args.workspace / "partial").mkdir(exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        tasks = [pool.submit(download_file, args.repo, info.sha, args.workspace, entry) for entry in files]
        for task in tasks:
            task.result()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("workspace", type=Path)
    parser.add_argument("parent_pid", type=int)
    parser.add_argument("--include", action="append")
    args = parser.parse_args()
    if os.getppid() != args.parent_pid:
        return 1
    Thread(target=stop_when_app_closes, args=(args.parent_pid,), daemon=True).start()

    try:
        with (args.workspace / "job.lock").open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            download_package(args)
    except BlockingIOError:
        print("已有进程正在处理这个下载任务。")
        return 1
    except Exception as error:
        print(f"{type(error).__name__}：{error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
