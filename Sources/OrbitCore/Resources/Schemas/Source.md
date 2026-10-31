---
id: "orbit-schema-source-v1"
title: "Source schema"
type: "schema"
summary: "Version 1 requirements for Orbit source notes."
schema_for: "source"
schema_version: 1
required_fields: ["id", "title", "type", "summary"]
required_sections: []
validation: "warn"
---
# Source schema

Store source notes in Sources/ and originals in Sources/assets/. Preserve original bytes and separate source statements from synthesis. Record the source location, capture scope, extraction gaps, and verified dates or hashes when available.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
