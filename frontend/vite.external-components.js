import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);

export function wirejacExternalComponentDependencies() {
  const clientModules = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    ".jac/client/node_modules"
  );

  return {
    name: "wirejac-external-component-dependencies",
    resolveId(source, importer) {
      if (!importer || source.startsWith(".") || source.startsWith("/")) {
        return null;
      }
      try {
        return require.resolve(source, { paths: [clientModules] });
      } catch {
        return null;
      }
    },
  };
}
