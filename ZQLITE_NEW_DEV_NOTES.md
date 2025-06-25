# ZQLite v0.4.0 Developer Migration Guide

## 🚀 Major Updates & Breaking Changes

ZQLite v0.4.0 introduces significant performance optimizations, security hardening, and new SQL features. This guide covers the integration steps needed for all dependent projects.

---

## 🔧 **API Changes & Migration Steps**

### **1. Encryption Module Changes**
**BREAKING CHANGE**: Encryption initialization now requires salt management.

**Old Code:**
```zig
var encryption = try Encryption.init("password");
```

**New Code:**
```zig
// For new databases (generates random salt)
var encryption = try Encryption.init("password", null);

// For existing databases (load stored salt)
const stored_salt = loadSaltFromHeader(); // Your implementation
var encryption = try Encryption.initWithSalt("password", stored_salt);

// Important: Store the salt for future use
const salt = encryption.getSalt();
// Save salt to database header/metadata
```

**Action Required for All Projects:**
- Update encryption initialization calls
- Implement salt storage in database headers
- Add salt loading logic for existing databases

### **2. Memory Management Updates**
**NEW FEATURE**: Pooled memory allocation for better performance.

**Integration Steps:**
```zig
// Get pooled allocator from storage engine
const pooled_allocator = storage_engine.getPooledAllocator();

// Use pooled allocator for frequent allocations
const data = try pooled_allocator.alloc(u8, size);
defer pooled_allocator.free(data);

// Monitor memory usage
const stats = storage_engine.getMemoryStats();
std.log.info("Memory pools: {d}, Total allocated: {d}", .{stats.total_pools, stats.total_allocated});

// Cleanup unused pools periodically
storage_engine.cleanupMemory();
```

### **3. Updated Column Structure for Aggregates**
**BREAKING CHANGE**: SELECT column structure has changed to support aggregate functions.

**Old Code:**
```zig
const column = ast.Column{
    .name = "user_id",
    .alias = null,
};
```

**New Code:**
```zig
const column = ast.Column{
    .expression = ast.ColumnExpression{ .Simple = "user_id" },
    .alias = null,
};

// For aggregate functions
const count_column = ast.Column{
    .expression = ast.ColumnExpression{ 
        .Aggregate = ast.AggregateFunction{
            .function_type = .Count,
            .column = null, // COUNT(*)
        }
    },
    .alias = "total_count",
};
```

---

## 📊 **Project-Specific Integration Guides**

### **Zepplin (Zig Package Manager)**

#### **Package Metadata Storage**
```zig
// Use JOINs for dependency queries
const query = 
    \\SELECT p.name, p.version, d.dependency_name, d.version_constraint
    \\FROM packages p
    \\INNER JOIN dependencies d ON p.id = d.package_id
    \\WHERE p.name = ?
;

// Aggregate package statistics
const stats_query =
    \\SELECT 
    \\  COUNT(*) as total_packages,
    \\  AVG(download_count) as avg_downloads,
    \\  MAX(version) as latest_version
    \\FROM packages 
    \\GROUP BY author
;
```

#### **Memory Optimization for Large Registries**
```zig
// Use memory pools for package parsing
const pooled_alloc = registry.storage.getPooledAllocator();

// Batch operations with arena allocator
var arena = std.heap.ArenaAllocator.init(pooled_alloc);
defer arena.deinit();
const temp_alloc = arena.allocator();

// Parse multiple packages efficiently
for (package_files) |file| {
    const parsed = try parsePackage(temp_alloc, file);
    try registry.addPackage(parsed);
}
// Arena automatically cleans up all temporary allocations
```

#### **Secure Package Verification**
```zig
// Enhanced encryption for package signatures
var encryption = try Encryption.init(signing_key, null);
defer encryption.deinit();

// Store salt in registry metadata
const registry_header = RegistryHeader{
    .version = REGISTRY_VERSION,
    .encryption_salt = encryption.getSalt(),
    .created_at = std.time.timestamp(),
};
```

---

### **GhostMesh (Mesh Networking)**

#### **Peer Relationship Management**
```zig
// Use JOINs for mesh topology queries
const topology_query =
    \\SELECT 
    \\  p1.node_id as source,
    \\  p2.node_id as target,
    \\  c.latency,
    \\  c.bandwidth,
    \\  c.reliability
    \\FROM peers p1
    \\INNER JOIN connections c ON p1.id = c.source_peer_id
    \\INNER JOIN peers p2 ON c.target_peer_id = p2.id
    \\WHERE c.status = 'active'
    \\ORDER BY c.reliability DESC
;
```

#### **Network Metrics Aggregation**
```zig
// Real-time network statistics
const metrics_query =
    \\SELECT 
    \\  node_region,
    \\  COUNT(*) as peer_count,
    \\  AVG(latency) as avg_latency,
    \\  SUM(bandwidth) as total_bandwidth,
    \\  MIN(last_seen) as oldest_activity
    \\FROM peer_metrics 
    \\WHERE last_seen > datetime('now', '-1 hour')
    \\GROUP BY node_region
;
```

#### **Encrypted Mesh State Storage**
```zig
// Secure storage for mesh topology
const mesh_encryption = try Encryption.init(mesh_secret, null);
defer mesh_encryption.deinit();

// Store encryption salt in mesh configuration
const mesh_config = MeshConfig{
    .mesh_id = mesh_id,
    .encryption_salt = mesh_encryption.getSalt(),
    .node_count = active_nodes,
};
```

---

### **CNS (Container Networking System)**

#### **Container Network Tracking**
```zig
// Network namespace and container relationships
const network_query =
    \\SELECT 
    \\  c.container_id,
    \\  c.name as container_name,
    \\  n.namespace_id,
    \\  n.network_cidr,
    \\  i.ip_address,
    \\  i.interface_name
    \\FROM containers c
    \\INNER JOIN network_interfaces i ON c.id = i.container_id
    \\INNER JOIN network_namespaces n ON i.namespace_id = n.id
    \\WHERE c.status = 'running'
;
```

#### **Network Performance Metrics**
```zig
// Aggregate network statistics per namespace
const performance_query =
    \\SELECT 
    \\  namespace_id,
    \\  COUNT(*) as active_containers,
    \\  SUM(bytes_transmitted) as total_tx,
    \\  SUM(bytes_received) as total_rx,
    \\  AVG(packet_loss_rate) as avg_packet_loss
    \\FROM network_stats 
    \\WHERE timestamp > datetime('now', '-5 minutes')
    \\GROUP BY namespace_id
    \\HAVING avg_packet_loss < 0.01
;
```

#### **Secure Network Configuration Storage**
```zig
// Encrypted storage for network policies
const cns_encryption = try Encryption.init(network_key, stored_salt);
defer cns_encryption.deinit();

// High-performance config caching
const pooled_alloc = cns.storage.getPooledAllocator();
const config_cache = try NetworkConfigCache.init(pooled_alloc);
```

---

### **Jarvis (AI Assistant)**

#### **Conversation History with Context**
```zig
// Complex conversation queries with JOINs
const context_query =
    \\SELECT 
    \\  c.id as conversation_id,
    \\  c.title,
    \\  m.content as message,
    \\  m.role,
    \\  m.timestamp,
    \\  u.username
    \\FROM conversations c
    \\INNER JOIN messages m ON c.id = m.conversation_id
    \\INNER JOIN users u ON c.user_id = u.id
    \\WHERE c.user_id = ? 
    \\  AND m.timestamp > datetime('now', '-24 hours')
    \\ORDER BY m.timestamp DESC
    \\LIMIT 100
;
```

#### **AI Model Performance Analytics**
```zig
// Aggregate model performance metrics
const analytics_query =
    \\SELECT 
    \\  model_name,
    \\  COUNT(*) as request_count,
    \\  AVG(response_time_ms) as avg_response_time,
    \\  AVG(token_count) as avg_tokens,
    \\  SUM(compute_cost) as total_cost
    \\FROM ai_requests 
    \\WHERE created_at > datetime('now', '-1 day')
    \\GROUP BY model_name
    \\ORDER BY request_count DESC
;
```

#### **Secure User Data Management**
```zig
// Encrypted user preferences and history
const jarvis_encryption = try Encryption.init(user_key, null);

// Memory-efficient conversation processing
var arena = std.heap.ArenaAllocator.init(jarvis.storage.getPooledAllocator());
defer arena.deinit();

// Process large conversation histories efficiently
const conversations = try loadUserConversations(arena.allocator(), user_id);
```

---

### **CIPHER (Cryptographic Operations)**

#### **Enhanced Key Management**
```zig
// Multi-layer encryption with proper salt management
const master_encryption = try Encryption.init(master_key, null);
const master_salt = master_encryption.getSalt();

// Store salt securely
const key_header = CipherKeyHeader{
    .version = CIPHER_VERSION,
    .algorithm = "ChaCha20-Poly1305",
    .salt = master_salt,
    .key_derivation_rounds = 4096,
};
```

#### **Cryptographic Audit Logging**
```zig
// Secure audit trail with aggregation
const audit_query =
    \\SELECT 
    \\  operation_type,
    \\  COUNT(*) as operation_count,
    \\  MIN(timestamp) as first_operation,
    \\  MAX(timestamp) as last_operation,
    \\  COUNT(DISTINCT user_id) as unique_users
    \\FROM crypto_audit_log 
    \\WHERE timestamp > datetime('now', '-1 week')
    \\  AND success = true
    \\GROUP BY operation_type
    \\ORDER BY operation_count DESC
;
```

#### **High-Performance Crypto Operations**
```zig
// Use memory pools for crypto buffers
const crypto_alloc = cipher.storage.getPooledAllocator();

// Batch encryption operations
var operations = std.ArrayList(CryptoOperation).init(crypto_alloc);
defer operations.deinit();

// Process multiple items efficiently
for (data_items) |item| {
    const encrypted = try encryptItem(crypto_alloc, item);
    try operations.append(encrypted);
}
```

---

## ⚠️ **Critical Migration Checklist**

### **For All Projects:**

1. **[ ] Update Encryption Initialization**
   - Replace `Encryption.init(password)` with `Encryption.init(password, null)`
   - Implement salt storage/loading logic
   - Test with existing encrypted databases

2. **[ ] Update Column Parsing**
   - Replace direct `.name` access with `.expression.Simple`
   - Add support for aggregate column expressions
   - Update query builders and parsers

3. **[ ] Integrate Memory Pooling**
   - Use `getPooledAllocator()` for frequent allocations
   - Add periodic `cleanupMemory()` calls
   - Monitor memory usage with `getMemoryStats()`

4. **[ ] Test Performance**
   - Benchmark against previous version
   - Verify JOIN operations work correctly
   - Test aggregate functions with large datasets

5. **[ ] Update Dependencies**
   - Ensure Zig version compatibility
   - Update build scripts and CI/CD
   - Test all integration points

### **Security Validation:**
```bash
# Verify salt randomness
zig test src/db/encryption.zig

# Performance benchmarks
zig test src/db/btree.zig
zig test src/db/pager.zig

# Memory pool efficiency
zig test src/db/memory_pool.zig
```

---

## 🎯 **Performance Gains Expected**

| Operation | Before | After | Improvement |
|-----------|---------|-------|-------------|
| B-Tree Search | O(n) | O(log n) | ~90% faster for large datasets |
| Cache Operations | O(n) | O(1) | ~95% faster LRU management |
| Memory Allocation | System malloc | Pooled | ~50% reduction in fragmentation |
| JOIN Queries | Not supported | Optimized algorithms | New capability |
| Aggregate Functions | Not supported | Native support | New capability |

---

## 📞 **Support & Troubleshooting**

### **Common Migration Issues:**

1. **Encryption Salt Errors:**
   - Ensure salt is stored and loaded correctly
   - Verify salt length is exactly 32 bytes
   - Check that salt is preserved across database opens

2. **Memory Pool Issues:**
   - Call `cleanupMemory()` periodically
   - Monitor memory usage in long-running processes
   - Use arena allocators for temporary bulk operations

3. **Column Expression Errors:**
   - Update all column parsing code
   - Use `.expression.Simple` for regular columns
   - Handle `.expression.Aggregate` for functions

### **Testing Your Migration:**
```zig
// Comprehensive migration test
test "migration compatibility" {
    // Test encryption with salt
    var encryption = try Encryption.init("test", null);
    defer encryption.deinit();
    
    // Test memory pooling
    const pooled_alloc = storage.getPooledAllocator();
    const data = try pooled_alloc.alloc(u8, 1024);
    defer pooled_alloc.free(data);
    
    // Test column expressions
    const column = ast.Column{
        .expression = .{ .Simple = "test_column" },
        .alias = null,
    };
    
    // Test aggregates
    const count_col = ast.Column{
        .expression = .{ 
            .Aggregate = .{
                .function_type = .Count,
                .column = null,
            }
        },
        .alias = "count",
    };
}
```

---

## 🚀 **Next Steps**

1. **Update each project using this guide**
2. **Run comprehensive tests**
3. **Monitor performance improvements**
4. **Report any issues or migration problems**
5. **Consider enabling new features (JOINs, aggregates)**

This migration unlocks significant performance improvements and new SQL capabilities while maintaining backward compatibility where possible. The enhanced security and memory management provide a solid foundation for production deployments.