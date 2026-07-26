/**
 * Components kept as TSX source files resolve packages from the project root,
 * while Jac installs browser dependencies under .jac/client/node_modules.
 */
export function wirejacExternalComponentDependencies() {
  return {
    name: "wirejac-external-component-dependencies",
    async resolveId(source, importer) {
      const isBareImport =
        !source.startsWith(".") && !source.startsWith("/") && !source.startsWith("\0");
      const isSourceComponent = importer?.includes("/components/");

      if (!isBareImport || !isSourceComponent) {
        return null;
      }

      const resolved = await this.resolve(source, undefined, { skipSelf: true });
      return resolved?.id ?? null;
    },
  };
}
