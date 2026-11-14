# VocalisMeta integration — 14 November 2026

For the subsequent contract v4 integration, see [the v4 rollout and recovery guide](vocalismeta-v4.md). The notes below describe the earlier v1/v2/v3 integration.

The reviewed source is [kladhest-se/vocalismeta](https://github.com/kladhest-se/vocalismeta), revision `0a39e452f6b7421169274e91fc17704b1e9f18d5`, verified against public GitHub HEAD. The local checkout was clean. The agent remains unchanged by this work.

VocalisBook already supported the v1 recording identities, v2 work grouping, v3 contributor identities, Swedish rating provenance and deterministic narrator-name fallback identities. This update adds the following client improvements:

- Preserve the first provider series as the primary membership, while retaining all exact secondary memberships. Series standing and next-book suggestions use that order; counts remain scoped to the selected book's library.
- Read and display the recording release date, publisher and provider-normalized Plex rating score. Recording dates remain separate from the literary work's first-publication year. Plex's score out of ten displays out of five; provider and vote count accompany it only when available. A changed provider cannot inherit an old provider's score/count.
- Treat complete book-detail responses as authoritative, including intentionally removed relationships. Partial list responses retain richer cached values until detail refresh finishes. This allows rejected Open Library work relationships or disabled agent namespaces to disappear from the apps without removing independently valid narrator and recording metadata.
- Keep a persisted detail-refresh backlog separate from list timestamps. The fifty-book refresh cap no longer strands remaining books. Failed detail attempts rotate behind untried work. Migration v18 marks existing cached projections for refresh and retains the underlying metadata and listening state.
- Preserve a known recording identity when a response from the same library omits GUID, while continuing to honor explicit identity changes. Recording identity remains the owner of progress, bookmarks and completion; work and contributor identities do not own progress.

The apps read normal authenticated Plex metadata. They do not call Audible, Ljudboksarkivet, Open Library or agent-internal tools directly. Newer matching controls, per-book overrides, diagnostics and artwork-validation reports remain agent-side features; their accepted results reach the apps through Plex.

The published v1/v2/v3 vector files and supplemental Unicode vectors are copied unchanged into PlexKit's test resources, with source revision and the original MIT notice. Tests execute every published v1/v2/v3 case and verify consumption of the published Unicode narrator/local wire identities. The apps consume the agent's fingerprint values; they do not recompute name or local-book fingerprints. Composed/decomposed display names remain exact, and name-backed narrator keys retain their non-authoritative meaning.

To pick up new metadata, refresh the book in VocalisMeta/Plex first, then refresh the library or reopen the book in VocalisBook. Large libraries consume the saved detail backlog in bounded batches. Provider failures retain the last valid cached detail until a successful authoritative response arrives.

See the agent's [player integration contract](https://github.com/kladhest-se/vocalismeta/blob/0a39e452f6b7421169274e91fc17704b1e9f18d5/CLIENT_INTEGRATION.md) and [contract fixtures](https://github.com/kladhest-se/vocalismeta/tree/0a39e452f6b7421169274e91fc17704b1e9f18d5/client-contract).

Validation passed: **563 package tests** (133 PlexKit, 331 Audiobooks, 56 Platform/Shared and 43 Mac platform), **69 offline release-tool tests**, platform consistency checks and unsigned iOS/macOS/tvOS app builds. This includes 34 new package tests in this follow-up. Live Plex/iCloud delivery, signed-device playback and native file-picker round trips remain device checks. No production accounts, user databases or audio files were changed during validation.
