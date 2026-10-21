import {ProductItem} from './ProductItem';
import type {Product} from '../lib/types';

export function ProductGrid({products}: {products: Product[]}) {
  return (
    <div className="product-grid">
      {products.map((product, index) => (
        <ProductItem
          key={product.id}
          product={product}
          loading={index < 4 ? 'eager' : 'lazy'}
        />
      ))}
    </div>
  );
}
