import {Link} from 'react-router';

export function CartBadge({count}: {count: number}) {
  return <Link to="/cart">Cart ({count})</Link>;
}
