import {PRODUCT_ITEM_FRAGMENT} from './fragments';
import type {Product} from './types';

const CATALOG: Product[] = [
  {id: 'p1', handle: 'canvas-tote', title: 'Canvas Tote', description: 'A sturdy tote.', price: {amount: '24.00', currencyCode: 'USD'}, imageUrl: '/img/tote.png', available: true},
  {id: 'p2', handle: 'enamel-mug', title: 'Enamel Mug', description: 'Holds coffee.', price: {amount: '14.50', currencyCode: 'USD'}, imageUrl: '/img/mug.png', available: true},
];

export const PRODUCT_QUERY = `#graphql
  query Product($handle: String!) { product(handle: $handle) { ...ProductItem } }
  ${PRODUCT_ITEM_FRAGMENT}
`;

export async function getProduct(handle: string): Promise<Product | null> {
  return CATALOG.find((p) => p.handle === handle) ?? null;
}

export async function listProducts(): Promise<Product[]> {
  return CATALOG;
}
