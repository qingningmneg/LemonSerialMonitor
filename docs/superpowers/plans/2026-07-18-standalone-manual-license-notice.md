# Standalone Manual License Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the standalone DOCX/PDF manual carry a prominent Chinese MIT summary and the complete canonical MIT license text, including the exact owner and attribution requirement.

**Architecture:** Keep the existing manual generator as the only content source. It reads repository-root `LICENSE`, writes a navigation-page callout and a page-broken appendix, then its structural audit pins the required legal phrases. Regenerate and visually verify the checked-in DOCX/PDF from that source.

**Tech Stack:** Python with `python-docx`, PowerShell 5.1 with Pester 4.10.1, LibreOffice headless, Poppler PNG rendering, bundled Codex document runtime.

## Global Constraints

- Public product names are only `Lemon串口监控` and `Lemon Serial Monitor`.
- License text comes from repository-root `LICENSE`; no second handwritten legal-text source is allowed.
- Commercial and for-profit use is allowed, but copies or substantial portions must retain `Copyright (c) 2026 qingningmneg` and the MIT license notice.
- Preserve the sixteen existing operating sections, installation steps, AI guidance, page geometry, and visual system.
- Do not publish until the regenerated manual and full clean release build pass.

---

### Task 1: Add the manual license contract with TDD

**Files:**
- Modify: `tests/powershell/License.Tests.ps1`
- Modify: `tests/powershell/BilingualDocs.Tests.ps1`
- Modify: `scripts/docs/build_commmonitor_manual.py`

**Interfaces:**
- Consumes: canonical UTF-8 text at repository-root `LICENSE`.
- Produces: `add_canonical_license_appendix(doc: Document) -> None` and a structural audit contract.

- [ ] **Step 1: Write the failing test**

Add `$manualBuilderPath = Join-Path $repoRoot 'scripts\docs\build_commmonitor_manual.py'`, then add:

```powershell
It 'embeds the canonical MIT terms in the standalone manual' {
    $builder = Get-RequiredUtf8Content -Path $manualBuilderPath
    if ($null -eq $builder) { return }
    foreach ($requiredText in @(
            'LICENSE_PATH = ROOT / "LICENSE"',
            '开源与署名',
            '允许商业使用和盈利',
            'Copyright (c) 2026 qingningmneg',
            '附录：MIT License',
            'license_text = LICENSE_PATH.read_text(encoding="utf-8")',
            'The above copyright notice and this permission notice shall be included')) {
        $builder.Contains($requiredText) | Should Be $true
    }
}
```

- [ ] **Step 2: Verify RED**

Run `Invoke-Pester -Script .\tests\powershell\License.Tests.ps1 -PassThru`.

Expected: one new failure because the builder does not yet read or embed the canonical license.

- [ ] **Step 3: Implement the minimum source change**

Add `LICENSE_PATH = ROOT / "LICENSE"` near `OUTPUT_PATH`, then add:

```python
def add_canonical_license_appendix(doc: Document) -> None:
    license_text = LICENSE_PATH.read_text(encoding="utf-8")
    if license_text.startswith("\ufeff"):
        raise RuntimeError("canonical LICENSE must be UTF-8 without BOM")
    for required in (
        "MIT License",
        "Copyright (c) 2026 qingningmneg",
        "The above copyright notice and this permission notice shall be included",
        "THE SOFTWARE IS PROVIDED \"AS IS\"",
    ):
        if required not in license_text:
            raise RuntimeError(f"canonical LICENSE is missing: {required}")

    add_page_break(doc)
    add_heading(doc, "附录：MIT License", 1)
    add_paragraph(
        doc,
        "以下为仓库根目录 LICENSE 的完整规范文本；安装目录中的副本位于 docs\\LICENSE.txt。",
    )
    for block in license_text.strip().split("\n\n"):
        paragraph = doc.add_paragraph()
        paragraph.paragraph_format.space_after = Pt(8)
        paragraph.paragraph_format.line_spacing = 1.08
        for index, line in enumerate(block.splitlines()):
            if index:
                paragraph.add_run().add_break()
            set_run_font(paragraph.add_run(line), size=9.5, color=INK)
```

Immediately after the navigation table, add:

```python
add_callout(
    doc,
    "开源与署名",
    "本软件按 MIT 许可证开源，允许免费使用、修改、分发、商业使用和盈利。复制或分发本软件或其实质部分时，必须保留 Copyright (c) 2026 qingningmneg 版权声明和 MIT 许可声明。完整条款见手册末尾附录或安装目录 docs\\LICENSE.txt。",
    "note",
)
```

Call `add_canonical_license_appendix(doc)` after the final `证据原则` callout. Add these values to the audit `required` tuple: `开源与署名`, `允许商业使用和盈利`, `MIT License`, the exact copyright line, the permission-notice inclusion sentence, and `THE SOFTWARE IS PROVIDED "AS IS"`.

Set `doc.core_properties.revision = 3`; extend keywords with `Lemon Serial Monitor,serial monitor,COM port,serial sniffer,open source,MIT`; change the BilingualDocs source assertion from revision 2 to 3.

- [ ] **Step 4: Verify GREEN**

Run both `License.Tests.ps1` and `BilingualDocs.Tests.ps1` with Pester.

Expected: every focused test passes with zero failures.

- [ ] **Step 5: Commit the tested source**

```powershell
git add -- tests/powershell/License.Tests.ps1 tests/powershell/BilingualDocs.Tests.ps1 scripts/docs/build_commmonitor_manual.py
git commit -m "docs: embed MIT license in standalone manual"
```

---

### Task 2: Regenerate and visually verify the manual

**Files:**
- Modify: `scripts/docs/build_commmonitor_manual.py`
- Modify: `docs/superpowers/plans/2026-07-18-standalone-manual-license-notice.md`
- Modify: `manual/Lemon串口监控-完整操作手册.docx`
- Modify: `manual/Lemon串口监控-完整操作手册.pdf`
- Generated QA only: `artifacts/manual/`, `artifacts/manual-render/`

**Interfaces:**
- Consumes: `build_document() -> Document` and repository-root `LICENSE`.
- Produces: release-ready DOCX/PDF with a verified rendered page count of 16.

- [ ] **Step 1: Generate the DOCX**

```powershell
$python = 'C:\Users\Admin\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python .\scripts\docs\build_commmonitor_manual.py
if ($LASTEXITCODE) { throw 'Manual generator failed.' }
```

Set `EXPECTED_RENDERED_PAGE_COUNT = 16`, regenerate, and require the structural audit to report `PASS` with `Pages=16`. Visual QA found that the first render contained a mostly empty seventeenth-page layout because a naturally split table was immediately followed by a redundant forced page break. Removing only that break keeps the sixteen operating sections intact, lets the checklist use the available page space, and leaves the canonical MIT appendix on its own final page.

- [ ] **Step 2: Render the DOCX to PDF and PNGs**

```powershell
$renderer = 'C:\Users\Admin\.codex\plugins\cache\openai-primary-runtime\documents\26.715.12143\skills\documents\render_docx.py'
$renderRoot = '.\artifacts\manual-render'
Remove-Item -LiteralPath $renderRoot -Recurse -Force -ErrorAction SilentlyContinue
& $python $renderer '.\artifacts\manual\Lemon串口监控-完整操作手册.docx' --output_dir $renderRoot --emit_pdf
if ($LASTEXITCODE) { throw 'DOCX render failed.' }
```

Expected: one non-empty PDF and exactly sixteen `page-*.png` files.

- [ ] **Step 3: Inspect every page at original detail**

Open all sixteen PNGs. Reject missing glyphs, clipping, overlap, broken tables, large accidental blanks, misplaced headings/footers, or incomplete license text.

- [ ] **Step 4: Verify the emitted PDF text**

Use bundled `pypdf` to require PDF page count 16 and all of: `开源与署名`, `允许商业使用和盈利`, `MIT License`, exact copyright, the permission-notice inclusion sentence, and the `AS IS` disclaimer. Reject the retired public product name.

- [ ] **Step 5: Promote only verified artifacts**

Copy the regenerated DOCX and emitted PDF to the stable `manual` filenames. Re-run the generator structural audit and calculate fresh SHA-256 hashes.

- [ ] **Step 6: Run regression gates**

Run `License.Tests.ps1`, `BilingualDocs.Tests.ps1`, `Package.Tests.ps1`, and `ReleasePackage.Tests.ps1`; run `scripts/Test-LemonBrand.ps1`; run `git diff --check`. Every command must exit 0.

- [ ] **Step 7: Commit the verified artifacts**

```powershell
git add -- manual scripts/docs/build_commmonitor_manual.py docs/superpowers/plans/2026-07-18-standalone-manual-license-notice.md tests/powershell/License.Tests.ps1 tests/powershell/BilingualDocs.Tests.ps1
git commit -m "docs: publish self-contained licensed manual"
```

The complete release build, installation/uninstallation acceptance, GitHub metadata update, and v0.1.1 publication remain separate release gates after this plan.
