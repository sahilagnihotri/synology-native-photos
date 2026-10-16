
---
## albums-core worker, 2026-10-16 (context: first)

Measured against the real NAS (DSM 7.3.2, Personal space, read only):
- Info: Browse.Album maxVersion 5, Browse.Item maxVersion 7, Browse.NormalAlbum maxVersion 4.
- `Browse.Album list` v1, v2, v4 with `additional=["thumbnail"]`: `{"data":{"list":[]},"success":true}`. The account has ZERO albums, so no album element shape was ever captured.
- `Browse.Album list` v4 WITHOUT `additional`: `{"error":{"code":101}}`. `NormalAlbum list` also 101 without additional; with additional it returns an empty list.
- `Browse.Item list` v2/v4 `additional=["thumbnail","resolution"]` element: `{"id":73609,"filename":"IMG_7521.HEIC","filesize":1960491,"time":1784754229,"indexed_time":1788724426229,"owner_user_id":1,"folder_id":385,"type":"photo","additional":{"resolution":{"width":3024,"height":3024},"thumbnail":{"m":"ready","xl":"ready","preview":"broken","sm":"ready","cache_key":"55932_1788825603","unit_id":55932},"orientation":1,"orientation_original":1}}`.
- Item list v4 with unknown param `foo=1`: ignored (normal page). `album_id=0`: ignored (normal page). `album_id=1` and `album_id=999999`: `{"error":{"code":609}}`. So album_id is read and a missing album is 609.
- Item list v1 with `additional` gave 101 in one early probe (v2 and v4 fine); use v4 as the app does.
- NOT verified: the item list of a non-empty album, because no album exists and writes are forbidden. The mock fixture reuses the plain Item list element above.

Results: 217 passed, 0 failed, 1 ignored across synology-api; clippy clean. Falsified: renaming the `album_id` query key made 2 of 4 `album_items_mock` tests fail; restored, 4 pass.
