import {Link} from 'react-router';
import {Image} from './Image';
import {Money} from './Money';
import type {Product} from '../lib/types';

type ProductItemProps = {
  product: Product;
  loading?: 'eager' | 'lazy';
};

export function ProductItem({product, loading}: ProductItemProps) {
  return (
    <Link className="product-item" to={`/products/${product.handle}`}>
      <Image src={product.imageUrl} alt={product.title} loading={loading} />
      <h4>{product.title}</h4>
      <Money data={product.price} />
    </Link>
  );
}
