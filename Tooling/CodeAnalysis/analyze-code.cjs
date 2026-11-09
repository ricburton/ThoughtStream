// Static analysis only: input is data, never evaluated or imported as a module.
const prettier = require("prettier");
const { Linter } = require("eslint");
const recommended = require("@eslint/js").configs.recommended;
const globals = require("globals");
const { HtmlValidate } = require("html-validate");

async function analyze({ source, language }) {
  let formatted = source;
  const diagnostics = [];
  const diagnostic = (code, message, line = 1, column = 1, endLine = line, endColumn = column) =>
    ({ code, message, line, column, endLine, endColumn });
  try {
    formatted = await prettier.format(source, {
      parser: language === "html" ? "html" : "babel",
      printWidth: 88, tabWidth: 2, useTabs: false,
    });
  } catch (error) {
    diagnostics.push(diagnostic("syntax", String(error.message).split("\n")[0], error.loc?.start?.line, error.loc?.start?.column));
  }
  if (language === "javascript") {
    const linter = new Linter();
    const options = {
      languageOptions: {
        ecmaVersion: "latest", sourceType: "module",
        parserOptions: { ecmaFeatures: { jsx: true } },
        globals: { ...globals.browser, ...globals.node },
      },
      rules: recommended.rules,
    };
    const messages = linter.verify(formatted, options, { filename: "snippet.js", allowInlineConfig: false });
    diagnostics.push(...messages.map(m => diagnostic(m.ruleId || "syntax", m.message, m.line, m.column, m.endLine, m.endColumn)));
  } else {
    const validator = new HtmlValidate({
      extends: ["html-validate:recommended", "html-validate:prettier"],
      rules: { "require-doctype": "off" },
    });
    const report = await validator.validateString(formatted);
    diagnostics.push(...report.results.flatMap(r => r.messages.map(m =>
      diagnostic(m.ruleId || "syntax", m.message, m.line, m.column, m.line, m.column + (m.size || 1)))));
  }
  const unique = [...new Map(diagnostics.map(d => [`${d.code}:${d.line}:${d.column}:${d.message}`, d])).values()];
  return { source, formatted, diagnostics: unique, state: unique.length ? "issues" : "clean", message: null };
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { input += chunk; });
process.stdin.on("end", async () => {
  try { process.stdout.write(JSON.stringify(await analyze(JSON.parse(input)))); }
  catch (error) { process.stderr.write(String(error.message)); process.exitCode = 1; }
});
