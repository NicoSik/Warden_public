type ImageProps = {
  src: string;
  alt: string;
  loading?: 'eager' | 'lazy';
};

export function Image({src, alt, loading = 'lazy'}: ImageProps) {
  return <img src={src} alt={alt} loading={loading} />;
}
