import type {Product} from './types';

export function productMeta(product: Product) {
  return [
    {title: `${product.title} | Storefront`},
    {name: 'description', content: product.description.slice(0, 150)},
  ];
}
