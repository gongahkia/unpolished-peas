import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

const typedRules = tseslint.configs.strictTypeChecked.map((config) => ({
  ...config,
  files: ['**/*.ts'],
}));

export default tseslint.config(
  {
    ignores: ['**/dist/**', '**/coverage/**', '**/node_modules/**', 'crates/pxcl-wasm/pkg/**'],
  },
  eslint.configs.recommended,
  ...typedRules,
  {
    files: ['**/*.ts'],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
);
