"""Короткая блокировка общего состояния новостей между процессами."""

import os
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def state_lock(data_dir: Path):
    """Даёт единственному владельцу менять data_dir; занятое состояние не перезаписывает."""
    data_dir.mkdir(parents=True, exist_ok=True)
    with (data_dir / "state.lock").open("a+b") as handle:
        os.chmod(handle.name, 0o600)
        if os.name == "nt":
            import msvcrt
            handle.seek(0, os.SEEK_END)
            if not handle.tell():
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                raise RuntimeError("news_state_busy") from None
        else:
            import fcntl
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise RuntimeError("news_state_busy") from None
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)
