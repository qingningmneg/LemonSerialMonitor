# Standalone Manual License Notice Design

## Context

The version 0.1.1 PDF manual is a standalone GitHub Release asset. The repository, installer, and release bundle distribute the standard MIT License, but the manual itself does not yet state the commercial-use permission or attribution requirement.

## Goal

Make the standalone Chinese manual accurately explain that Lemon串口监控 is MIT-licensed, that commercial and for-profit use is allowed, and that copies or substantial portions must retain `Copyright (c) 2026 qingningmneg` and the MIT license notice.

## Approaches Considered

1. Add a concise front-matter callout and a full-license appendix generated directly from the canonical root `LICENSE`. This is prominent, keeps the sixteen operating sections unchanged, and makes a separately shared PDF self-contained without hand-maintained legal text. This is the selected approach.
2. Add only a full-license appendix. This is legally complete but makes the permission and attribution rule easy to miss during normal use.
3. Add a notice to every footer. This is highly visible but distracts from instructions and uses limited footer space on every page.

## Design

- Insert one `开源与署名` callout immediately after the navigation table.
- State the exact MIT permission and retention rule in plain Chinese.
- Add a page-broken `附录：MIT License` after the existing final checklist and evidence callout.
- Read the appendix text directly from repository-root `LICENSE`; do not maintain a second handwritten legal-text source.
- Name the canonical installed location `docs\LICENSE.txt` in the front-matter callout.
- Preserve the existing visual system, section numbering, installation steps, and AI guidance.

## Verification

- Add a failing contract test before editing the generator. It must require the exact owner, MIT, commercial/profit permission, retention language, canonical root-license read, and full-license appendix in the manual source/audit contract.
- Regenerate the DOCX with the pinned bundled Python runtime.
- Convert the regenerated DOCX to PDF and render every page to PNG.
- Inspect every page for missing glyphs, clipping, overlap, table splits, broken headings, and page-number problems.
- Update the pinned rendered page count only if the verified render actually changes it.
- Re-run the manual structural audit, license tests, bilingual/version tests, brand guard, and the full release build from a clean committed revision.

## Acceptance Criteria

- A reader who only downloads the PDF can tell that commercial use and profit are allowed.
- The same reader can tell that the copyright and MIT license notices must be retained.
- The standalone PDF contains the complete canonical MIT permission and warranty-disclaimer text.
- The exact owner is `qingningmneg` and the year is 2026.
- The generated DOCX and PDF remain visually clean and release-ready.
