---
# epi-221o
title: add table for info/list
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-23T03:15:23Z
blocked_by:
    - epi-q25u
    - epi-jcjq
---

Replace plain text list/info output with a formatted table using [comfy-table](https://crates.io/crates/comfy-table) (v7.2.2).

## Why comfy-table

- Stable (post-1.0, author considers it "finished")
- Minimal deps (unicode-segmentation + unicode-width)
- Builder API fits our data flow — rows are assembled from multiple sources, not a single struct
- tabled's derive macro doesn't help here: conditional columns (PROJECT), multi-source row assembly, sectioned key-value layout in info

## Approach

Introduce display structs (e.g. ListRow, InfoView) that assemble all data upfront, separating data gathering from rendering. This makes output testable and keeps comfy-table usage contained to the rendering step.

### cmd_list
- Define a ListRow struct with pre-formatted fields: name, target, status, ssh, project (Option), ports
- Build Vec<ListRow> from instance_store::list() + runtime queries
- Render with comfy-table, conditionally adding PROJECT column when any row has Some(project)
- Preserve status_dot() and strip_home() transforms during struct construction

### cmd_info
- Define an InfoView struct with sections as fields (identity, resources, network: Option, mounts: Option, runtime: Option)
- Render each section as a borderless two-column comfy-table (key, value)
- Skip None sections

## Tasks
- [x] Add comfy-table dependency
- [x] Define display structs (ListRow, InfoView)
- [x] Refactor cmd_list to build ListRow vec then render with comfy-table
- [x] Refactor cmd_info to build InfoView then render with comfy-table
- [x] Update e2e tests for new output format (no changes needed — e2e tests don't assert on list/info output)
- [x] Changelog entry

## Summary of Changes

Replaced manual println! formatting in `cmd_list` and `cmd_info` with comfy-table (v7.2.2) for aligned column output. Introduced display structs (`ListRow`, `InfoView`/`InfoSection`) to separate data assembly from rendering. Info output now uses a single table across all sections so values share one aligned column.
