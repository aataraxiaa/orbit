# Overview retrieval candidate

Overview queries favour matching project entries, dated status, decisions and
explicit supersession over historical companion notes. Packing includes
complete paragraphs from complementary sections, skips a whole paragraph when it
cannot fit, and returns selected lines in original source order. Each paragraph
includes its authoritative section and full line range, independently of whether
a heading is returned. Scope filtering
precedes date selection. A dated status section is kept together instead of being
mixed with old change logs from the same note. Dates rank only saved evidence;
they do not prove current provider coverage or live external task state.

A matched private-copy check with three results and a 12 KB serialized evidence
budget now includes purpose, problem, decision evolution, latest saved date,
completed work, pending work and a synchronization qualification. This is a narrow
labelled case, not general skill parity. Smaller budgets and larger result counts
can omit essential context. Research qualifications and broad paraphrase coverage
remain separate evaluation gaps. No private notes or model replies are published.

The app candidate gives Apple Intelligence section provenance, removes opaque task
identifiers only from the overview model projection, and identifies the newest
dated status heading among supplied evidence. Original excerpts, identifiers,
hashes and line numbers remain intact for source inspection. The host checks the
model's token capacity where the system API supports counting. Apple generation
still requires real-device and answer-quality acceptance; unit and Mac probes do
not establish iPhone behavior. Markdown format and snapshot archive schema do not
change, and no user-data migration is required.

The paragraph-context follow-up adds an optional derived `paragraphs` field to
retrieval evidence. Each entry identifies the section and inclusive source-line
range of a complete captured paragraph or list item. It does not assert that the
whole section or document was returned. Consumers must preserve every line of a
selected paragraph and its section qualification; old results without this proof
cannot support the app's verified passage-selection mode. The snapshot archive and
Markdown format remain unchanged. The app experiment uses a 16 KB evidence budget
for this additional provenance. Its literal-passage output is longer than a natural
summary and remains a test candidate, not a production or device-acceptance claim.
