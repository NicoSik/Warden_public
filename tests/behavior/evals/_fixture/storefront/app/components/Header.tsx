import {Link} from 'react-router';
import {CartBadge} from './CartBadge';

export function Header({itemCount}: {itemCount: number}) {
  return (
    <header className="header">
      <Link to="/">Storefront</Link>
      <nav>
        <Link to="/collections/all">Shop</Link>
        <CartBadge count={itemCount} />
      </nav>
    </header>
  );
}
