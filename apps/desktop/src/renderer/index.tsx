import { createRoot } from 'react-dom/client';

import { App } from './App';
import './styles.css';

const rootElement = document.getElementById('root');
if (rootElement === null) {
  throw new Error('缺少 #root 挂载点');
}

createRoot(rootElement).render(<App />);
