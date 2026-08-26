import { isRequestId } from '@coc-helper/contracts';

type SenderId = number;

type RequestEntry = {
  readonly controller: AbortController;
  cancelled: boolean;
};

/** Main 进程内的请求取消注册表；requestId 只在 sender 范围内有意义。 */
export class RequestCancellationRegistry {
  private readonly requests = new Map<SenderId, Map<string, RequestEntry>>();

  start(senderId: SenderId, requestId: string): AbortSignal {
    if (!isRequestId(requestId)) {
      throw new RangeError('requestId 不合法。');
    }
    const senderRequests = this.requests.get(senderId) ?? new Map<string, RequestEntry>();
    if (senderRequests.has(requestId)) {
      throw new Error('requestId 已在该 sender 下注册。');
    }
    const controller = new AbortController();
    senderRequests.set(requestId, { controller, cancelled: false });
    this.requests.set(senderId, senderRequests);
    return controller.signal;
  }

  cancel(senderId: SenderId, requestId: string): boolean {
    if (!isRequestId(requestId)) {
      return false;
    }
    const senderRequests = this.requests.get(senderId);
    const entry = senderRequests?.get(requestId);
    if (entry === undefined || entry.cancelled) {
      return false;
    }
    entry.cancelled = true;
    entry.controller.abort();
    return true;
  }

  finish(senderId: SenderId, requestId: string): boolean {
    if (!isRequestId(requestId)) {
      return false;
    }
    const senderRequests = this.requests.get(senderId);
    if (senderRequests === undefined || !senderRequests.delete(requestId)) {
      return false;
    }
    if (senderRequests.size === 0) {
      this.requests.delete(senderId);
    }
    return true;
  }

  clearSender(senderId: SenderId): number {
    const senderRequests = this.requests.get(senderId);
    if (senderRequests === undefined) {
      return 0;
    }
    for (const entry of senderRequests.values()) {
      if (!entry.cancelled) {
        entry.cancelled = true;
        entry.controller.abort();
      }
    }
    const count = senderRequests.size;
    this.requests.delete(senderId);
    return count;
  }
}
