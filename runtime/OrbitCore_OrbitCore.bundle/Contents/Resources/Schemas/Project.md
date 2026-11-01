---
id: "orbit-schema-project-v1"
title: "Project schema"
type: "schema"
summary: "Version 1 requirements for Orbit project notes."
schema_for: "project"
schema_version: 1
required_fields: ["id", "title", "type", "summary", "status"]
required_sections: ["Purpose", "Current state"]
validation: "warn"
---
# Project schema

Keep the project overview in Projects/<project>/Overview.md. Summarize the current state and link to canonical decisions, knowledge, sources, and sessions. Do not copy their full contents here.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
