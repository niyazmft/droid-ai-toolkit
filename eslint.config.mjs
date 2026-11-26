import js from "@eslint/js";
import globals from "globals";
import jsonc from "eslint-plugin-jsonc";

export default [
  {
    // Mandatory Ignores
    ignores: ["node_modules/**", "dist/**", "build/**", "apk/**/build/**", ".obsidian/**"],
  },
  js.configs.recommended,
  {
    files: ["**/*.{js,mjs}"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        ...globals.node,
        ...globals.browser,
        ...globals.jest,
      },
    },
    rules: {
      "no-unused-vars": ["warn", { argsIgnorePattern: "^_" }],
      "no-console": "off",
    },
  },
  ...jsonc.configs["flat/recommended-with-json"],
];
