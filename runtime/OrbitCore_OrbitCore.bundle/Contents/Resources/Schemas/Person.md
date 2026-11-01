---
id: "orbit-schema-person-v1"
title: "Person schema"
type: "schema"
summary: "Version 1 requirements for Orbit person notes."
schema_for: "person"
schema_version: 1
required_fields: ["id", "title", "type", "summary"]
required_sections: []
validation: "warn"
---
# Person schema

Store people in People/. Save only relevant user-requested information and retain its source. Link to projects instead of duplicating project details.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
