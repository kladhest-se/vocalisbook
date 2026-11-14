# Client-facing Plex response fixtures

These are synthetic, realistic single-album Plex API JSON/XML examples, not live
server captures. They contain public illustrative recording IDs and invented book
metadata, no account tokens or private file paths. Read JSON Mood[].tag or XML
Directory/Mood/@tag. All detail fixtures bind the v4 recording_key to the album's
normal VocalisMeta GUID. updatedAt/thumb demonstrate native Plex fields; they are
not inputs to v4 revisions. disabled_legacy_response.json intentionally contains
no v4 chunks. Corresponding decoded expected payloads and inputs are frozen in
../../test-vectors-v4.json. The XML covers fresh, unavailable, and verified-upgrade
cases. Real Plex/AgentKit transport validation remains deferred.
