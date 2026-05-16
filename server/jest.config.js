export default {
  preset: 'ts-jest/presets/default-esm',
  testEnvironment: 'node',
  extensionsToTreatAsEsm: ['.ts'],
  moduleNameMapper: {
    '^(\\.{1,2}/.*)\\.js$': '$1',
  },
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        useESM: true,
        // 151002 recommends `isolatedModules: true`, which is incompatible
        // with ts-jest's ESM transform (breaks `import` emit). tsconfig.test.json
        // is the real type gate for tests; this warning is noise here.
        diagnostics: { ignoreCodes: [151002] },
      },
    ],
  },
  testMatch: ['**/tests/**/*.test.ts'],
  collectCoverageFrom: ['src/**/*.ts'],
  // Ratchet: raise these as coverage climbs. `index.ts` is the bin entrypoint
  // (socket + stdio wiring) and is not unit-tested yet — issue #97 step 4
  // tracks covering it before its threshold is lifted off the floor. A path
  // entry is subtracted from `global`, so `global` covers every other file.
  coverageThreshold: {
    global: {
      statements: 94,
      branches: 87,
      functions: 90,
      lines: 95,
    },
    './src/index.ts': {
      statements: 0,
      branches: 0,
      functions: 0,
      lines: 0,
    },
  },
};
