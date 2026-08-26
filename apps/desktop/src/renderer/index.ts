import './styles.css';

const status = document.getElementById('status');

void window.cocHelper
  .health()
  .then((result) => {
    if (status !== null) {
      status.textContent = result.ok ? 'Electron 宿主已就绪' : '宿主未就绪';
    }
  })
  .catch(() => {
    if (status !== null) {
      status.textContent = '宿主健康检查失败';
    }
  });
