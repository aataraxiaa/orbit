---
id: "orbit-schema-concept-v1"
title: "Concept schema"
type: "schema"
summary: "Version 1 requirements for Orbit concept notes."
schema_for: "concept"
schema_version: 1
required_fields: ["id", "title", "type", "summary"]
required_sections: []
validation: "warn"
---
# Concept schema

Store reusable knowledge in Knowledge/. Maintain one coherent note for a concept. Project and session notes link here when the knowledge is reusable. Preserve evidence and qualifications when updating it.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
