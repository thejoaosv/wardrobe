import { forwardRef } from "react";
import { Image } from "@unpic/react";

const IPX_OPTIONS = { ipx: { baseURL: "/_ipx" } };
const DEFAULT_BREAKPOINTS = [160, 240, 320, 480, 640, 800, 960, 1280];

function sourcePath(src) {
  if (!src || typeof src !== "string") return src;
  return src.split(/[?#]/, 1)[0];
}

export const OptimizedImage = forwardRef(function OptimizedImage({
  src,
  alt = "",
  sizes = "100vw",
  breakpoints = DEFAULT_BREAKPOINTS,
  quality = 80,
  priority = false,
  loading,
  decoding,
  ...props
}, ref) {
  const normalizedSource = sourcePath(src);

  if (!normalizedSource || normalizedSource.startsWith("data:") || normalizedSource.startsWith("blob:")) {
    return <img ref={ref} src={src} alt={alt} sizes={sizes} loading={loading || (priority ? "eager" : "lazy")} decoding={decoding || "async"} {...props} />;
  }

  // The wardrobe's own images: the server resizes them to a WebP preview with ?w=, instead of sending the full PNG.
  if (normalizedSource.startsWith("/api/")) {
    const sized = (width) => `${src}${src.includes("?") ? "&" : "?"}w=${width}`;
    return <img ref={ref} src={sized(breakpoints[breakpoints.length - 1])} srcSet={breakpoints.map((width) => `${sized(width)} ${width}w`).join(", ")} alt={alt} sizes={sizes} loading={loading || (priority ? "eager" : "lazy")} decoding={decoding || "async"} {...props} />;
  }

  return (
    <Image
      ref={ref}
      src={normalizedSource}
      alt={alt}
      fallback="ipx"
      options={IPX_OPTIONS}
      operations={{ ipx: { quality } }}
      layout="fullWidth"
      unstyled
      sizes={sizes}
      breakpoints={breakpoints}
      priority={priority}
      loading={loading}
      decoding={decoding}
      {...props}
    />
  );
});
