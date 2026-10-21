export const MONEY_FRAGMENT = `#graphql
  fragment Money on MoneyV2 {
    amount
    currencyCode
  }
`;

export const PRODUCT_ITEM_FRAGMENT = `#graphql
  fragment ProductItem on Product {
    id
    handle
    title
    availableForSale
    featuredImage { url }
    priceRange { minVariantPrice { ...Money } }
  }
  ${MONEY_FRAGMENT}
`;

export const CART_FRAGMENT = `#graphql
  fragment Cart on Cart {
    id
    lines(first: 50) { nodes { quantity merchandise { ... on ProductVariant { id } } } }
  }
`;
