"""The single JSON state object: GCS in production, a local file or memory otherwise.

update() is a read-modify-write retried on a generation conflict, so two Cloud Run
instances never lose each other's writes.
"""

from __future__ import annotations

import json
import os
import threading
from typing import Callable, TypeVar

T = TypeVar("T")


class Conflict(Exception):
    pass


class Store:
    def load(self) -> tuple[dict, object]:
        raise NotImplementedError

    def save(self, state: dict, generation: object) -> None:
        raise NotImplementedError

    def read(self) -> dict:
        return self.load()[0]

    def update(self, fn: Callable[[dict], T], attempts: int = 5) -> T:
        for _ in range(attempts):
            try:
                state, gen = self.load()
                result = fn(state)
                self.save(state, gen)
                return result
            except Conflict:
                continue
        raise Conflict("state kept changing; gave up")


class MemoryStore(Store):
    def __init__(self, state: dict | None = None):
        self._data = json.dumps(state or {})
        self._gen = 0
        self._lock = threading.Lock()

    def load(self):
        with self._lock:
            return json.loads(self._data), self._gen

    def save(self, state, generation):
        with self._lock:
            if generation != self._gen:
                raise Conflict()
            self._data = json.dumps(state)
            self._gen += 1


class FileStore(MemoryStore):
    def __init__(self, path: str):
        self.path = path
        super().__init__(json.load(open(path)) if os.path.exists(path) else {})

    def save(self, state, generation):
        super().save(state, generation)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, self.path)
        os.chmod(self.path, 0o600)


class GcsStore(Store):
    def __init__(self, bucket: str, name: str):
        from google.cloud import storage  # imported lazily: tests never need it

        self._blob_name = name
        self._bucket = storage.Client().bucket(bucket)

    def load(self):
        from google.api_core.exceptions import NotFound, PreconditionFailed

        blob = self._bucket.blob(self._blob_name)
        try:
            blob.reload()
            return json.loads(blob.download_as_bytes(if_generation_match=blob.generation)), blob.generation
        except NotFound:
            return {}, 0
        except PreconditionFailed as e:
            raise Conflict() from e

    def save(self, state, generation):
        from google.api_core.exceptions import PreconditionFailed

        blob = self._bucket.blob(self._blob_name)
        try:
            blob.upload_from_string(json.dumps(state), content_type="application/json", if_generation_match=generation)
        except PreconditionFailed as e:
            raise Conflict() from e
