import {useLoaderData} from 'react-router';
import {ProductDetails} from '../components/ProductDetails';
import {getProduct} from '../lib/storefront';
import {productMeta} from '../lib/seo';

export async function loader({params}: {params: {handle: string}}) {
  const product = await getProduct(params.handle);
  if (!product) throw new Response('Not found', {status: 404});
  return {product};
}

export const meta = ({data}: {data: {product: Parameters<typeof productMeta>[0]}}) =>
  productMeta(data.product);

export default function ProductPage() {
  const {product} = useLoaderData<typeof loader>();
  return <ProductDetails product={product} />;
}
