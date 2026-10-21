import {Image} from './Image';
import {Money} from './Money';
import {AddToCartButton} from './AddToCartButton';
import type {Product} from '../lib/types';

export function ProductDetails({product}: {product: Product}) {
  return (
    <section className="product-details">
      <Image src={product.imageUrl} alt={product.title} loading="eager" />
      <h1>{product.title}</h1>
      <Money data={product.price} />
      <p>{product.description}</p>
      <AddToCartButton productId={product.id} disabled={!product.available} />
    </section>
  );
}
