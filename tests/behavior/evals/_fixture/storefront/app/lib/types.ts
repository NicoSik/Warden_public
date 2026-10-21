export type Money = {amount: string; currencyCode: string};

export type Product = {
  id: string;
  handle: string;
  title: string;
  description: string;
  price: Money;
  imageUrl: string;
  available: boolean;
};

export type CartLine = {
  productId: string;
  quantity: number;
};

export type Cart = {
  id: string;
  lines: CartLine[];
};
