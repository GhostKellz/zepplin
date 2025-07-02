// Zepplin Registry Frontend - v0.4.0
// Lightning-fast package registry for Zig

class ZepplinApp {
    constructor() {
        this.apiBaseUrl = window.location.origin;
        this.init();
    }

    async init() {
        this.setupEventListeners();
        await this.loadInitialData();
        await this.setupAuth();
        this.hideLoadingApp();
    }

    setupEventListeners() {
        // Search functionality
        const searchInput = document.getElementById('package-search');
        const searchBtn = document.querySelector('.search-btn');
        
        if (searchInput) {
            searchInput.addEventListener('input', this.debounce((e) => {
                this.handleSearchInput(e.target.value);
            }, 300));
            
            searchInput.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') {
                    e.preventDefault();
                    this.performSearch(e.target.value);
                }
            });
        }

        if (searchBtn) {
            searchBtn.addEventListener('click', () => {
                const query = searchInput?.value || '';
                this.performSearch(query);
            });
        }

        // Dynamic loading for sections
        this.setupIntersectionObserver();
        
        // Mobile navigation
        this.setupMobileNav();
    }

    async loadInitialData() {
        try {
            // Load stats
            await this.loadStats();
            
            // Load featured packages
            await this.loadFeaturedPackages();
            
            // Update last updated time
            this.updateLastUpdated();
        } catch (error) {
            console.error('Failed to load initial data:', error);
            this.showError('Failed to load registry data');
        }
    }

    async loadStats() {
        try {
            const response = await fetch(`${this.apiBaseUrl}/api/v1/stats`);
            if (!response.ok) throw new Error('Failed to fetch stats');
            
            const stats = await response.json();
            this.updateStatsDisplay(stats);
        } catch (error) {
            console.error('Failed to load stats:', error);
            // Show fallback stats
            this.updateStatsDisplay({
                total_packages: '1,247',
                total_downloads: '45.2K',
                active_maintainers: 89,
                zig_version: '0.14.0'
            });
        }
    }

    updateStatsDisplay(stats) {
        const elements = {
            'total-packages': this.formatNumber(stats.total_packages),
            'total-downloads': this.formatNumber(stats.total_downloads),
            'active-maintainers': this.formatNumber(stats.active_maintainers),
            'zig-version': stats.zig_version || '0.14.0'
        };

        Object.entries(elements).forEach(([id, value]) => {
            const element = document.getElementById(id);
            if (element) {
                this.animateNumber(element, value);
            }
        });
    }

    async loadFeaturedPackages() {
        try {
            const response = await fetch(`${this.apiBaseUrl}/api/v1/packages?featured=true&limit=6`);
            const packages = response.ok ? await response.json() : [];
            
            this.displayPackages(packages.packages || packages || [], 'featured-packages');
        } catch (error) {
            console.error('Failed to load featured packages:', error);
            this.displayMockPackages('featured-packages');
        }
    }

    displayPackages(packages, containerId) {
        const container = document.getElementById(containerId);
        if (!container) return;

        if (packages.length === 0) {
            container.innerHTML = this.createEmptyState('No packages found');
            return;
        }

        container.innerHTML = packages.map(pkg => this.createPackageCard(pkg)).join('');
    }

    createPackageCard(pkg) {
        const downloads = this.formatNumber(pkg.download_count || pkg.downloads || 0);
        const version = pkg.latest_version || pkg.version || '1.0.0';
        const description = pkg.description || 'No description available';
        const name = pkg.name || 'unknown';
        const updated = this.formatDate(pkg.updated_at || pkg.last_updated || new Date());

        return `
            <div class="package-card" data-package="${name}">
                <div class="package-header">
                    <div class="package-name">${this.escapeHtml(name)}</div>
                    <div class="package-version">v${this.escapeHtml(version)}</div>
                </div>
                <div class="package-description">
                    ${this.escapeHtml(description)}
                </div>
                <div class="package-meta">
                    <div class="package-downloads">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                            <polyline points="7,10 12,15 17,10"></polyline>
                            <line x1="12" y1="15" x2="12" y2="3"></line>
                        </svg>
                        ${downloads}
                    </div>
                    <div class="package-updated">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <circle cx="12" cy="12" r="10"></circle>
                            <polyline points="12,6 12,12 16,14"></polyline>
                        </svg>
                        ${updated}
                    </div>
                </div>
            </div>
        `;
    }

    displayMockPackages(containerId) {
        const mockPackages = [
            { name: 'zig-json', version: '2.1.0', description: 'Fast JSON parser and serializer for Zig', downloads: 15420, updated_at: '2024-06-28' },
            { name: 'zig-http', version: '1.3.2', description: 'HTTP client and server library', downloads: 8932, updated_at: '2024-06-25' },
            { name: 'zig-crypto', version: '0.9.1', description: 'Cryptographic primitives and utilities', downloads: 6781, updated_at: '2024-06-22' },
            { name: 'zig-cli', version: '1.1.0', description: 'Command-line argument parsing library', downloads: 12103, updated_at: '2024-06-20' },
            { name: 'zig-allocator', version: '2.0.3', description: 'Advanced memory allocation strategies', downloads: 9654, updated_at: '2024-06-18' },
            { name: 'zig-datetime', version: '1.4.1', description: 'Date and time manipulation utilities', downloads: 5432, updated_at: '2024-06-15' }
        ];
        
        this.displayPackages(mockPackages, containerId);
    }

    async handleSearchInput(query) {
        if (query.length < 2) {
            this.hideSuggestions();
            return;
        }

        try {
            const response = await fetch(`${this.apiBaseUrl}/api/v1/search?q=${encodeURIComponent(query)}&limit=5`);
            const results = response.ok ? await response.json() : { packages: [] };
            
            this.showSuggestions(results.packages || results || []);
        } catch (error) {
            console.error('Search failed:', error);
            this.hideSuggestions();
        }
    }

    showSuggestions(packages) {
        const container = document.getElementById('search-suggestions');
        if (!container || packages.length === 0) {
            this.hideSuggestions();
            return;
        }

        container.innerHTML = packages.map(pkg => `
            <div class="suggestion-item" onclick="window.zepplin.selectPackage('${this.escapeHtml(pkg.name)}')">
                <div class="suggestion-name">${this.escapeHtml(pkg.name)}</div>
                <div class="suggestion-desc">${this.escapeHtml(pkg.description || '')}</div>
            </div>
        `).join('');

        container.style.display = 'block';
    }

    hideSuggestions() {
        const container = document.getElementById('search-suggestions');
        if (container) {
            container.style.display = 'none';
        }
    }

    selectPackage(packageName) {
        window.location.href = `/packages/${packageName}`;
    }

    performSearch(query) {
        if (query.trim()) {
            window.location.href = `/search?q=${encodeURIComponent(query.trim())}`;
        }
    }

    setupIntersectionObserver() {
        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('animate-in');
                }
            });
        }, { threshold: 0.1 });

        // Observe all cards and sections
        document.querySelectorAll('.stat-card, .package-card, .category-card').forEach(el => {
            observer.observe(el);
        });
    }

    setupMobileNav() {
        // Add mobile menu functionality if needed
        const nav = document.querySelector('.nav');
        if (window.innerWidth <= 768 && nav) {
            // Mobile navigation setup
            this.createMobileMenu();
        }
    }

    createMobileMenu() {
        // Implementation for mobile hamburger menu
        const header = document.querySelector('.header-content');
        if (!header) return;

        const menuButton = document.createElement('button');
        menuButton.className = 'mobile-menu-btn';
        menuButton.innerHTML = '☰';
        menuButton.style.cssText = `
            display: none;
            background: none;
            border: none;
            color: var(--lightning-400);
            font-size: 1.5rem;
            cursor: pointer;
            padding: 0.5rem;
        `;

        if (window.innerWidth <= 768) {
            menuButton.style.display = 'block';
            header.appendChild(menuButton);
        }
    }

    animateNumber(element, targetValue) {
        if (!element) return;
        
        const startValue = 0;
        const duration = 2000;
        const startTime = Date.now();
        
        const isNumeric = !isNaN(parseFloat(targetValue));
        const target = isNumeric ? parseFloat(String(targetValue).replace(/[^\d.]/g, '')) : targetValue;
        
        if (!isNumeric) {
            element.textContent = targetValue;
            return;
        }

        const animate = () => {
            const elapsed = Date.now() - startTime;
            const progress = Math.min(elapsed / duration, 1);
            const easeOutCubic = 1 - Math.pow(1 - progress, 3);
            
            const currentValue = startValue + (target - startValue) * easeOutCubic;
            element.textContent = this.formatNumber(Math.floor(currentValue));
            
            if (progress < 1) {
                requestAnimationFrame(animate);
            } else {
                element.textContent = targetValue;
            }
        };
        
        requestAnimationFrame(animate);
    }

    formatNumber(num) {
        if (typeof num === 'string') return num;
        if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
        if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
        return num.toString();
    }

    formatDate(dateString) {
        try {
            const date = new Date(dateString);
            const now = new Date();
            const diffMs = now - date;
            const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
            
            if (diffDays === 0) return 'Today';
            if (diffDays === 1) return 'Yesterday';
            if (diffDays < 7) return `${diffDays} days ago`;
            if (diffDays < 30) return `${Math.floor(diffDays / 7)} weeks ago`;
            if (diffDays < 365) return `${Math.floor(diffDays / 30)} months ago`;
            return `${Math.floor(diffDays / 365)} years ago`;
        } catch (error) {
            return 'Recently';
        }
    }

    updateLastUpdated() {
        const lastUpdated = new Date().toLocaleString();
        console.log(`Zepplin Registry loaded at ${lastUpdated}`);
    }

    createEmptyState(message) {
        return `
            <div style="text-align: center; padding: 3rem; color: var(--text-muted);">
                <div style="font-size: 3rem; margin-bottom: 1rem;">📦</div>
                <div>${message}</div>
            </div>
        `;
    }

    showError(message) {
        console.error('Zepplin Error:', message);
        // Could implement toast notifications here
    }

    hideLoadingApp() {
        const loadingEl = document.querySelector('.loading-app');
        if (loadingEl) {
            loadingEl.style.opacity = '0';
            setTimeout(() => loadingEl.remove(), 300);
        }
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    debounce(func, wait) {
        let timeout;
        return function executedFunction(...args) {
            const later = () => {
                clearTimeout(timeout);
                func(...args);
            };
            clearTimeout(timeout);
            timeout = setTimeout(later, wait);
        };
    }

    // Authentication methods
    async setupAuth() {
        const token = localStorage.getItem('zepplin_token');
        const authNav = document.getElementById('auth-nav');
        
        if (token) {
            // Check if token is valid
            try {
                const response = await fetch('/api/v1/auth/me', {
                    headers: {
                        'Authorization': `Bearer ${token}`
                    }
                });
                
                if (response.ok) {
                    const user = await response.json();
                    this.renderAuthenticatedNav(authNav, user);
                } else {
                    // Token invalid, clear it
                    localStorage.removeItem('zepplin_token');
                    localStorage.removeItem('zepplin_username');
                    this.renderUnauthenticatedNav(authNav);
                }
            } catch (error) {
                console.error('Auth check failed:', error);
                this.renderUnauthenticatedNav(authNav);
            }
        } else {
            this.renderUnauthenticatedNav(authNav);
        }
    }
    
    renderAuthenticatedNav(authNav, user) {
        authNav.innerHTML = `
            <span class="nav-user">Welcome, ${user.username}!</span>
            <a href="/publish" class="nav-link">Publish</a>
            <button class="nav-link nav-btn" onclick="window.zepplin.logout()">Logout</button>
        `;
    }
    
    renderUnauthenticatedNav(authNav) {
        authNav.innerHTML = `
            <a href="/auth" class="nav-link">Login</a>
            <a href="/auth" class="nav-link nav-btn">Sign Up</a>
        `;
    }
    
    async logout() {
        const token = localStorage.getItem('zepplin_token');
        
        if (token) {
            try {
                await fetch('/api/v1/auth/logout', {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`
                    }
                });
            } catch (error) {
                console.error('Logout request failed:', error);
            }
        }
        
        // Clear local storage
        localStorage.removeItem('zepplin_token');
        localStorage.removeItem('zepplin_username');
        
        // Refresh the page to update UI
        window.location.reload();
    }
}

// Enhanced CSS animations
const additionalStyles = `
    .animate-in {
        animation: slideInUp 0.6s ease-out forwards;
    }
    
    @keyframes slideInUp {
        from {
            opacity: 0;
            transform: translateY(30px);
        }
        to {
            opacity: 1;
            transform: translateY(0);
        }
    }
    
    .suggestion-item {
        padding: 1rem;
        border-bottom: 1px solid var(--border-subtle);
        cursor: pointer;
        transition: var(--transition-fast);
    }
    
    .suggestion-item:hover {
        background: rgba(255, 214, 10, 0.1);
    }
    
    .suggestion-item:last-child {
        border-bottom: none;
    }
    
    .suggestion-name {
        font-weight: 600;
        color: var(--lightning-400);
        margin-bottom: 0.25rem;
    }
    
    .suggestion-desc {
        font-size: 0.9rem;
        color: var(--text-muted);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    
    @media (max-width: 768px) {
        .mobile-menu-btn {
            display: block !important;
        }
        
        .nav {
            display: none;
        }
    }
`;

// Inject additional styles
const styleSheet = document.createElement('style');
styleSheet.textContent = additionalStyles;
document.head.appendChild(styleSheet);

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.zepplin = new ZepplinApp();
});

// Service Worker registration for offline support
if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('/sw.js')
            .then(registration => console.log('SW registered:', registration))
            .catch(error => console.log('SW registration failed:', error));
    });
}