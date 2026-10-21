import {useLoaderData} from 'react-router';
import {ProductGrid} from '../components/ProductGrid';
import {listProducts} from '../lib/storefront';

export async function loader() {
  return {products: await listProducts()};
}

export default function AllCollection() {
  const {products} = useLoaderData<typeof loader>();
  return (
    <main>
      <h1>All products</h1>
      <ProductGrid products={products} />
    </main>
  );
}
