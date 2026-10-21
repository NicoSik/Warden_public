import {useFetcher} from 'react-router';

type Props = {
  productId: string;
  disabled?: boolean;
};

export function AddToCartButton({productId, disabled}: Props) {
  const fetcher = useFetcher();
  return (
    <fetcher.Form method="post" action="/cart">
      <input type="hidden" name="productId" value={productId} />
      <button type="submit" disabled={disabled}>
        {disabled ? 'Sold out' : 'Add to cart'}
      </button>
    </fetcher.Form>
  );
}
