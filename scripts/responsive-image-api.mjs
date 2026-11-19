import path from "node:path";
import { createIPX, createIPXNodeServer, ipxFSStorage } from "ipx";

const DEFAULT_MAX_AGE = 24 * 60 * 60;
// The app asks for screen-sized images; anything larger is refused so a request can't make sharp allocate huge canvases.
const MAX_DIMENSION = 4096;

// True when the modifiers segment of /_ipx/<modifiers>/<path> names a size above MAX_DIMENSION.
export const oversized = (url = "") => (url.split("?")[0].split("/")[1]?.match(/\d+/g) || []).some((value) => Number(value) > MAX_DIMENSION);

export function responsiveImageApi(options = {}) {
  let handler;

  const attach = (server) => {
    server.middlewares.use("/_ipx", (req, res, next) => {
      if (!handler) return next();
      if (oversized(req.url)) {
        res.statusCode = 400;
        return res.end("Image size too large");
      }
      // shortcut: ipx re-processes every request (no disk cache); fine for the few public images, add one if that grows.
      return handler(req, res);
    });
  };

  return {
    name: "wardrobe-responsive-images",
    apply: "serve",
    configResolved(config) {
      const publicDir = path.resolve(config.publicDir || path.join(config.root, "public"));
      const buildDir = path.resolve(config.root, config.build.outDir || "dist");
      const storage = ipxFSStorage({
        dir: [publicDir, buildDir],
        maxAge: options.maxAge || DEFAULT_MAX_AGE,
      });
      const ipx = createIPX({
        storage,
      });
      handler = createIPXNodeServer(ipx);
    },
    configureServer: attach,
    configurePreviewServer: attach,
  };
}
