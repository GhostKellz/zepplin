// Zepplin Registry - Frontend JavaScript
class ZepplinUI {
    constructor() {
        this.apiBase = '/api/v1';
        this.searchDebounce = null;
        this.cache = new Map();
        
        this.init();
    }

    init() {
        this.setupEventListeners();
        this.loadFeaturedPackages();
        this.loadStats();
        this.setupSearchAutocomplete();
    }

    setupEventListeners() {
        // Search functionality
        const searchInput = document.getElementById('package-search');
        if (searchInput) {
            searchInput.addEventListener('input', (e) => {
                this.handleSearchInput(e.target.value);
            });
            
            searchInput.addEventListener('keypress', (e) => {
                if (e.key === 'Enter') {
                    this.performSearch(e.target.value);
                }
            });
        }

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.key === 'k') {
                e.preventDefault();
                searchInput?.focus();
            }
        });

        // Theme toggle (if implemented later)
        document.addEventListener('DOMContentLoaded', () => {
            this.setupIntersectionObserver();
            this.setupCopyCodeButtons();
        });
    }

    async loadStats() {
        try {
            const response = await this.fetchAPI('/stats');
            const stats = await response.json();
            
            this.updateElement('total-packages', this.formatNumber(stats.total_packages || 1247));
            this.updateElement('total-downloads', this.formatNumber(stats.total_downloads || 45200, true));
            this.updateElement('active-maintainers', stats.active_maintainers || 89);
            this.updateElement('zig-version', stats.zig_version || '0.14.0');
        } catch (error) {
            console.log('Using fallback stats');
        }
    }

    async loadFeaturedPackages() {
        try {
            const response = await this.fetchAPI('/packages/featured?limit=6');
            const data = await response.json();
            
            if (data.success && data.results) {
                this.renderPackages(data.results, 'featured-packages');
            } else {
                this.renderMockPackages();
            }
        } catch (error) {
            console.log('Loading mock featured packages');
            this.renderMockPackages();
        }
    }

    renderMockPackages() {
        const mockPackages = [
            {
                name: 'zig-clap',
                version: '0.6.0',
                description: 'Simple command line argument parsing library for Zig',
                author: 'Hejsil',
                download_count: 15420,
                updated_at: Date.now() - 86400000 * 2
            },
            {
                name: 'zap',
                version: '0.8.0',
                description: 'Blazingly fast web framework for Zig',
                author: 'zigzap',
                download_count: 8934,
                updated_at: Date.now() - 86400000 * 1
            },
            {
                name: 'raylib-zig',
                version: '4.5.0',
                description: 'Zig bindings for raylib game development library',
                author: 'Not-Nik',
                download_count: 12678,
                updated_at: Date.now() - 86400000 * 3
            },
            {
                name: 'zcrypto',
                version: '0.5.0',
                description: 'Pure Zig cryptographic library',
                author: 'ghostkellz',
                download_count: 6543,
                updated_at: Date.now() - 86400000 * 5
            },
            {
                name: 'zjson',
                version: '1.2.0',
                description: 'Fast JSON parser and serializer for Zig',
                author: 'json-zig',
                download_count: 9876,
                updated_at: Date.now() - 86400000 * 4
            },
            {
                name: 'zhttp',
                version: '0.9.0',
                description: 'HTTP client and server library for Zig',
                author: 'karlseguin',
                download_count: 11234,
                updated_at: Date.now() - 86400000 * 6
            }
        ];
        
        this.renderPackages(mockPackages, 'featured-packages');
    }

    renderPackages(packages, containerId) {
        const container = document.getElementById(containerId);
        if (!container) return;

        container.innerHTML = packages.map(pkg => `
            <div class="package-card" onclick="window.location.href='/packages/${pkg.name}'">
                <div class="package-header">
                    <a href="/packages/${pkg.name}" class="package-name">${pkg.name}</a>
                    <span class="package-version">v${pkg.version}</span>
                </div>
                <p class="package-description">${pkg.description}</p>
                <div class="package-meta">
                    <div class="package-downloads">
                        <span>📥</span>
                        <span>${this.formatNumber(pkg.download_count || 0)}</span>
                    </div>
                    <div class="package-updated">
                        <span>🕒</span>
                        <span>${this.timeAgo(pkg.updated_at)}</span>
                    </div>
                    ${pkg.author ? `<div class="package-author">👤 ${pkg.author}</div>` : ''}
                </div>
            </div>
        `).join('');
    }

    handleSearchInput(query) {
        clearTimeout(this.searchDebounce);
        
        if (query.length === 0) {
            this.hideSuggestions();
            return;
        }

        this.searchDebounce = setTimeout(() => {
            this.fetchSearchSuggestions(query);
        }, 300);
    }

    async fetchSearchSuggestions(query) {
        try {
            const response = await this.fetchAPI(`/search?q=${encodeURIComponent(query)}&limit=5`);
            const data = await response.json();
            
            if (data.success && data.results) {
                this.showSuggestions(data.results, query);
            }
        } catch (error) {
            console.log('Search suggestions failed:', error);
        }
    }

    showSuggestions(suggestions, query) {
        const container = document.getElementById('search-suggestions');
        if (!container || suggestions.length === 0) return;

        container.innerHTML = suggestions.map(pkg => `
            <div class="suggestion-item" onclick="this.searchResult('${pkg.name}')">
                <div class="suggestion-name">${this.highlightMatch(pkg.name, query)}</div>
                <div class="suggestion-description">${pkg.description || ''}</div>
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

    highlightMatch(text, query) {
        const regex = new RegExp(`(${query})`, 'gi');
        return text.replace(regex, '<mark>$1</mark>');
    }

    async performSearch(query) {
        if (!query.trim()) return;
        
        // Navigate to search results page
        window.location.href = `/packages?search=${encodeURIComponent(query)}`;
    }

    searchResult(packageName) {
        window.location.href = `/packages/${packageName}`;
    }

    async fetchAPI(endpoint) {
        const cacheKey = endpoint;
        
        if (this.cache.has(cacheKey)) {
            const cached = this.cache.get(cacheKey);
            if (Date.now() - cached.timestamp < 300000) { // 5 minutes
                return { json: () => Promise.resolve(cached.data) };
            }
        }

        const response = await fetch(this.apiBase + endpoint);
        
        if (response.ok) {
            const data = await response.json();
            this.cache.set(cacheKey, { data, timestamp: Date.now() });
            return { json: () => Promise.resolve(data) };
        }
        
        throw new Error(`API request failed: ${response.status}`);
    }

    setupIntersectionObserver() {
        const observerOptions = {
            threshold: 0.1,
            rootMargin: '0px 0px -50px 0px'
        };

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('fade-in');
                }
            });
        }, observerOptions);

        document.querySelectorAll('.package-card, .category-card, .stat-card').forEach(el => {
            observer.observe(el);
        });
    }

    setupCopyCodeButtons() {
        // Add copy buttons to code blocks (for documentation pages)
        document.querySelectorAll('pre code').forEach(block => {
            const button = document.createElement('button');
            button.className = 'copy-btn';
            button.textContent = 'Copy';
            button.onclick = () => this.copyToClipboard(block.textContent);
            
            block.parentElement.style.position = 'relative';
            block.parentElement.appendChild(button);
        });
    }

    async copyToClipboard(text) {
        try {
            await navigator.clipboard.writeText(text);
            this.showToast('Copied to clipboard!', 'success');
        } catch (error) {
            console.error('Copy failed:', error);
            this.showToast('Copy failed', 'error');
        }
    }

    showToast(message, type = 'info') {
        const toast = document.createElement('div');
        toast.className = `toast toast-${type}`;
        toast.textContent = message;
        
        document.body.appendChild(toast);
        
        setTimeout(() => toast.classList.add('show'), 100);
        setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => document.body.removeChild(toast), 300);
        }, 3000);
    }

    updateElement(id, value) {
        const element = document.getElementById(id);
        if (element) {
            element.textContent = value;
        }
    }

    formatNumber(num, abbreviated = false) {
        if (abbreviated) {
            if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
            if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
        }
        return num.toLocaleString();
    }

    timeAgo(timestamp) {
        const now = Date.now();
        const diff = now - timestamp;
        
        const minute = 60 * 1000;
        const hour = minute * 60;
        const day = hour * 24;
        const week = day * 7;
        const month = day * 30;
        const year = day * 365;

        if (diff < minute) return 'just now';
        if (diff < hour) return Math.floor(diff / minute) + 'm ago';
        if (diff < day) return Math.floor(diff / hour) + 'h ago';
        if (diff < week) return Math.floor(diff / day) + 'd ago';
        if (diff < month) return Math.floor(diff / week) + 'w ago';
        if (diff < year) return Math.floor(diff / month) + 'mo ago';
        return Math.floor(diff / year) + 'y ago';
    }
}

// Global search function for search button
function searchPackages() {
    const input = document.getElementById('package-search');
    if (input && input.value.trim()) {
        window.zepplinUI.performSearch(input.value.trim());
    }
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    // Initial page load animation
    document.body.style.opacity = '0';
    document.body.style.transition = 'opacity 0.5s ease-in';
    
    setTimeout(() => {
        document.body.style.opacity = '1';
    }, 100);
    
    // Animate hero elements on load
    const heroElements = document.querySelectorAll('.hero-title, .hero-subtitle, .search-container, .quick-actions');
    heroElements.forEach((el, index) => {
        el.style.opacity = '0';
        el.style.transform = 'translateY(20px)';
        el.style.transition = 'all 0.6s cubic-bezier(0.4, 0, 0.2, 1)';
        
        setTimeout(() => {
            el.style.opacity = '1';
            el.style.transform = 'translateY(0)';
        }, 200 + (index * 100));
    });
    
    // Initialize main UI
    window.zepplinUI = new ZepplinUI();
    
    // Animate stats numbers
    const animateNumber = (element) => {
        const endValue = parseInt(element.textContent.replace(/[^0-9]/g, ''));
        const duration = 2000;
        const start = Date.now();
        const startValue = 0;
        
        const animate = () => {
            const elapsed = Date.now() - start;
            const progress = Math.min(elapsed / duration, 1);
            const easeProgress = 1 - Math.pow(1 - progress, 3); // Ease out cubic
            const currentValue = Math.floor(startValue + (endValue - startValue) * easeProgress);
            
            element.textContent = window.zepplinUI.formatNumber(currentValue);
            
            if (progress < 1) {
                requestAnimationFrame(animate);
            } else {
                element.textContent = element.getAttribute('data-final') || window.zepplinUI.formatNumber(endValue);
            }
        };
        
        animate();
    };
    
    // Observe and animate stats
    const statsObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting && !entry.target.classList.contains('animated')) {
                entry.target.classList.add('animated');
                const number = entry.target.querySelector('.stat-number');
                if (number && !number.classList.contains('animated')) {
                    number.classList.add('animated');
                    setTimeout(() => animateNumber(number), 200);
                }
            }
        });
    }, { threshold: 0.3 });
    
    document.querySelectorAll('.stat-card').forEach(card => {
        statsObserver.observe(card);
    });
});

// Add fade-in animation CSS
const fadeInStyle = document.createElement('style');
fadeInStyle.textContent = `
    .fade-in {
        animation: fadeInUp 0.6s cubic-bezier(0.4, 0, 0.2, 1) forwards;
    }
    
    @keyframes fadeInUp {
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
        padding: 0.75rem 1rem;
        border-bottom: 1px solid var(--border-subtle);
        cursor: pointer;
        transition: all 0.2s ease;
    }
    
    .suggestion-item:hover {
        background: rgba(255, 214, 10, 0.1);
        border-color: var(--lightning-500);
        transform: translateX(5px);
    }
    
    .suggestion-item:last-child {
        border-bottom: none;
    }
    
    .suggestion-name {
        font-weight: 600;
        color: var(--lightning-400);
    }
    
    .suggestion-description {
        font-size: 0.9rem;
        color: var(--text-muted);
        margin-top: 0.25rem;
        opacity: 0.8;
    }
    
    mark {
        background: var(--lightning-500);
        color: white;
        padding: 0.1rem 0.2rem;
        border-radius: 2px;
    }
    
    .toast {
        position: fixed;
        top: 20px;
        right: 20px;
        padding: 1rem 1.5rem;
        border-radius: var(--border-radius-sm);
        color: white;
        font-weight: 500;
        z-index: 1000;
        transform: translateX(100%);
        transition: transform 0.3s ease;
    }
    
    .toast.show {
        transform: translateX(0);
    }
    
    .toast-success {
        background: var(--success);
    }
    
    .toast-error {
        background: var(--error);
    }
    
    .toast-info {
        background: var(--lightning-500);
    }
    
    .copy-btn {
        position: absolute;
        top: 0.5rem;
        right: 0.5rem;
        background: var(--bg-elevated);
        color: var(--text-secondary);
        border: 1px solid var(--border-default);
        padding: 0.25rem 0.75rem;
        border-radius: var(--border-radius-xs);
        font-size: 0.8rem;
        font-weight: 500;
        cursor: pointer;
        opacity: 0;
        transition: all 0.2s ease;
    }
    
    pre:hover .copy-btn {
        opacity: 1;
    }
    
    .copy-btn:hover {
        background: var(--lightning-500);
        color: var(--ocean-950);
        border-color: var(--lightning-500);
        transform: translateY(-2px);
        box-shadow: var(--shadow-sm);
    }
`;
document.head.appendChild(fadeInStyle);