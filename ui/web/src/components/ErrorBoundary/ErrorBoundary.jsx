import { Component } from 'react';
import StatusPage from '../StatusPage/StatusPage';
import log from '../../lib/log';
import { reportError } from '../../lib/sentry';

// Top-level error boundary: a render/lifecycle throw anywhere below this point
// (e.g. an unexpected-shape API field reaching a component) would otherwise
// unmount the whole SPA to a blank white screen. Instead we catch it, log it,
// and show the recoverable error page with a reload.
export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  componentDidCatch(error, info) {
    log.error('ErrorBoundary', `${error?.message || error}\n${info?.componentStack || ''}`);
    reportError(error, info?.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <StatusPage
          code="500"
          title="Something went wrong"
          message="Reloading usually fixes it. Contact support if it keeps happening."
          actionLabel="Reload"
          onAction={() => window.location.reload()}
        />
      );
    }
    return this.props.children;
  }
}
