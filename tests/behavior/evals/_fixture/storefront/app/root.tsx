import {Outlet} from 'react-router';
import {Header} from './components/Header';
import {Footer} from './components/Footer';

export default function App() {
  return (
    <>
      <Header itemCount={0} />
      <Outlet />
      <Footer />
    </>
  );
}
