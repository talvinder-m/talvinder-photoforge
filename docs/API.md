# PhotoForge local API

Other apps on the same Mac can read the open PhotoForge library, with your permission, through a small read-only HTTP API.

- **Off by default.** Turn it on in Settings › Sharing with other apps.
- **Only on this Mac.** It listens on `127.0.0.1` (default port 8765) and can't be reached from the network.
- **Read-only.** Only `GET` requests are accepted. Nothing can be changed or deleted through the API.
- **A token for every app.** Create one in Settings and choose what it may see:
  - `read`: names, dates, categories, people, albums and recognised text.
  - `thumbnails`: JPEG previews.
  - `originals`: the original photo files.

  The token is shown once. PhotoForge stores only its SHA-256 hash. Revoke a token at any time.

Every request needs the header `Authorization: Bearer <token>`.

| Status | Meaning |
|---|---|
| 200 | OK |
| 401 | Missing, wrong or revoked token |
| 403 | The token doesn't have the scope this path needs |
| 404 | Unknown path or item |
| 503 | No library is open |

## Endpoints

| Path | Scope | Returns |
|---|---|---|
| `GET /v1/library` | read | Name, kind and id of the open library, with photo, video, people and album counts |
| `GET /v1/categories` | read | `[{id, title, count}]` |
| `GET /v1/people` | read | Named people: `[{id, name, photos}]` |
| `GET /v1/albums` | read | PhotoForge albums and folders: `[{id, title, parent, isFolder, smart, count}]` |
| `GET /v1/tags` | read | Your tags: `[{name, count}]` |
| `GET /v1/assets` | read | `{total, offset, limit, items:[…]}`. Filters: `type=image\|video`, `category=<id>`, `album=<id>`, `tag=<name>`, `person=<id>`, `q=<text>` (names and text found in photos), `limit` (≤1000, default 100), `offset` |
| `GET /v1/assets/{id}` | read | One item, plus `people`, `albums`, `tags` and recognised `text` |
| `GET /v1/assets/{id}/thumbnail?size=512` | thumbnails | JPEG, 64–2048 px |
| `GET /v1/assets/{id}/original` | originals | The original file bytes (photos only) |

Each item has the fields `id`, `name`, `filename`, `type`, `created` (ISO 8601), `width`, `height`, `duration`, `favorite` and `categories`.

The API serves whichever library is open in PhotoForge. When you switch libraries, it serves the new one.

## Example

```sh
TOKEN=pf_…   # from Settings
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8765/v1/assets?category=receipt&limit=20"
curl -H "Authorization: Bearer $TOKEN" -o thumb.jpg "http://127.0.0.1:8765/v1/assets/42/thumbnail?size=800"
```

```python
import requests
h = {"Authorization": "Bearer " + TOKEN}
people = requests.get("http://127.0.0.1:8765/v1/people", headers=h).json()
```

## Reading the database directly

Tools can also read a library's SQLite database (see [LIBRARY_FORMAT.md](LIBRARY_FORMAT.md)). Open a **copy**, or open the file read-only. Never write to it while PhotoForge is running.

Face vectors are encrypted with the library's `vector.key` and are not meant for other apps.
