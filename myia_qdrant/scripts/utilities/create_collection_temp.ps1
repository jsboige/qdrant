$body = @{
    vectors = @{
        size = 1536
        distance = 'Cosine'
    }
    optimizers_config = @{
        max_indexing_threads = 2
        indexing_threshold = 10000
        flush_interval_sec = 10
    }
    hnsw_config = @{
        max_indexing_threads = 2
    }
} | ConvertTo-Json -Depth 5

$headers = @{
    'api-key' = $env:QDRANT_API_KEY
    'Content-Type' = 'application/json'
}

Invoke-RestMethod -Method PUT -Uri 'http://localhost:6333/collections/roo_tasks_semantic_index' -Headers $headers -Body $body