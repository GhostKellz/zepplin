// Registered as the @astrojs/alpinejs entrypoint. Runs before Alpine starts so
// the global `auth` store exists when components mount.
import type { Alpine } from 'alpinejs';

const KEYS = [
  'zepplin_token',
  'zepplin_username',
  'zepplin_display_name',
  'zepplin_avatar_url',
  'zepplin_email',
] as const;

// Ported verbatim from web/js/main.js so card/stat rendering matches the
// legacy output exactly.
function fmtNumber(num: number | string): string {
  if (typeof num === 'string') return num;
  if (num >= 1_000_000) return (num / 1_000_000).toFixed(1) + 'M';
  if (num >= 1_000) return (num / 1_000).toFixed(1) + 'K';
  return num.toString();
}

function fmtDate(dateString: string | number | Date | null | undefined): string {
  try {
    const date = new Date(dateString ?? Date.now());
    const diffDays = Math.floor((Date.now() - date.getTime()) / 86_400_000);
    if (diffDays === 0) return 'Today';
    if (diffDays === 1) return 'Yesterday';
    if (diffDays < 7) return `${diffDays} days ago`;
    if (diffDays < 30) return `${Math.floor(diffDays / 7)} weeks ago`;
    if (diffDays < 365) return `${Math.floor(diffDays / 30)} months ago`;
    return `${Math.floor(diffDays / 365)} years ago`;
  } catch {
    return 'Recently';
  }
}

async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to legacy path
  }
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

export default (Alpine: Alpine) => {
  Alpine.magic('fmtNumber', () => fmtNumber);
  Alpine.magic('fmtDate', () => fmtDate);
  Alpine.magic('copy', () => copyText);

  Alpine.store('auth', {
    ready: false,
    token: null as string | null,
    username: null as string | null,
    displayName: null as string | null,
    avatarUrl: '' as string,
    email: '' as string,

    get isLoggedIn(): boolean {
      return !!this.token;
    },

    get initial(): string {
      const name = this.displayName || this.username || '?';
      return name.charAt(0).toUpperCase();
    },

    async init() {
      this.token = localStorage.getItem('zepplin_token');
      this.username = localStorage.getItem('zepplin_username');
      this.displayName = localStorage.getItem('zepplin_display_name') || this.username;
      this.avatarUrl = localStorage.getItem('zepplin_avatar_url') || '';
      this.email = localStorage.getItem('zepplin_email') || '';

      if (this.token) {
        try {
          const res = await fetch('/api/v1/auth/me', {
            headers: { Authorization: `Bearer ${this.token}` },
          });
          if (res.ok) {
            const user = await res.json();
            this.displayName = this.displayName || user.username;
          } else {
            // Invalid/expired token -> logged out (mirrors legacy behavior).
            this.clear();
          }
        } catch {
          // Network error: keep optimistic logged-in state from localStorage,
          // matching the old catch path.
        }
      }
      this.ready = true;
    },

    clear() {
      KEYS.forEach((k) => localStorage.removeItem(k));
      this.token = null;
      this.username = null;
      this.displayName = null;
      this.avatarUrl = '';
      this.email = '';
    },

    async logout() {
      if (this.token) {
        try {
          await fetch('/api/v1/auth/logout', {
            method: 'POST',
            headers: { Authorization: `Bearer ${this.token}` },
          });
        } catch {
          // ignore network failure on logout
        }
      }
      this.clear();
      window.location.reload();
    },
  });

  document.addEventListener('alpine:init', () => {
    (Alpine.store('auth') as { init: () => void }).init();
  });
};
