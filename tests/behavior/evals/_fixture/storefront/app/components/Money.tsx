import {formatMoney} from '../lib/format';
import type {Money as MoneyType} from '../lib/types';

export function Money({data}: {data: MoneyType}) {
  return <span className="money">{formatMoney(data)}</span>;
}
