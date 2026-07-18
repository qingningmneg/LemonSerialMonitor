# Standalone Manual License Notice Design

## Context

The version 0.1.1 PDF manual is a standalone GitHub Release asset. The repository, installer, and release bundle distribute the standard MIT License, but the manual itself does not yet state the commercial-use permission or attribution requirement.

## Goal

Make the standalone Chinese manual accurately explain that Lemon串口监控 is MIT-licensed, that commercial and for-profit use is allowed, and that copies or substantial portions must retain `Copyright (c) 2026 qingningmneg` and the MIT license notice.

## Approaches Considered

1. Add a concise front-matter callout on the existing navigation page. This is prominent, keeps the manual task-focused, and does not renumber the sixteen operating sections. This is the selected approach.
2. Add a full-license appendix. This provides the complete legal text but duplicates the canonical `LICENSE`, increases page count, and makes future license synchronization harder.
3. Add a notice to every footer. This is highly visible but distracts from instructions and uses limited footer space on every page.

## Design

- Insert one `开源与署名` callout immediately after the navigation table.
- State the exact MIT permission and retention rule in plain Chinese.
- Name the canonical offline and online locations: installed `docs\LICENSE.txt` and repository-root `LICENSE`.
- Preserve the existing visual system, section numbering, installation steps, and AI guidance.
- Do not embed a second modified copy of the full MIT text in the manual.

## Verification

- Add a failing contract test before editing the generator. It must require the exact owner, MIT, commercial/profit permission, and retention language in the manual source/audit contract.
- Regenerate the DOCX with the pinned bundled Python runtime.
- Convert the regenerated DOCX to PDF and render every page to PNG.
- Inspect every page for missing glyphs, clipping, overlap, table splits, broken headings, and page-number problems.
- Update the pinned rendered page count only if the verified render actually changes it.
- Re-run the manual structural audit, license tests, bilingual/version tests, brand guard, and the full release build from a clean committed revision.

## Acceptance Criteria

- A reader who only downloads the PDF can tell that commercial use and profit are allowed.
- The same reader can tell that the copyright and MIT license notices must be retained.
- The exact owner is `qingningmneg` and the year is 2026.
- The generated DOCX and PDF remain visually clean and release-ready.
