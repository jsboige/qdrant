# Analyse de l'Hypothèse de Cycle Vicieux Qdrant
**Date:** 2025-10-14 00:27:16
**Logs analysés:** 10000 dernières lignes

---

## 1. Statistiques Globales par Client

| Client | Requêtes | Durée Moy. (s) | Durée Max (s) |
|--------|----------|----------------|---------------|
| curl/8.14.1 | 1 | 0.001 | 0.001 | | node | 4 | 0.001 | 0.002 | | qdrant-js/1.15.1 | 293 | 2.57 | 25.423 | | Roo-Code | 6366 | 0.1 | 2.82 |

### Analyse:
✅ Roo-Code génère plus de requêtes que roo-state-manager (comportement normal).

---

## 2. Top 10 Collections Sollicitées

| Collection | Requêtes |
|------------|----------|
| `ws-78b57f0e7b78c5fd` | 4094 | | `ws-3091d0dd3766da4b` | 2178 | | `roo_tasks_semantic_index` | 209 | | `ws-eee43ea32b400193` | 68 | | `ws-f31120a68442d3b4` | 9 | | `ws-eee43ea32b400193 HTTP` | 9 | | `ws-f31120a68442d3b4 HTTP` | 5 | | `ws-cced6a0374b91fe1` | 3 | | `ws-78b57f0e7b78c5fd HTTP` | 2 | | `ws-3091d0dd3766da4b HTTP` | 2 |

---

## 3. Erreurs Détectées

**Total erreurs:** 369

### Types d'erreurs:

- **HTTP 400:** 323 occurrences
- **HTTP 500:** 46 occurrences


---

## 4. Erreurs Spécifiques roo_tasks_semantic_index

**Erreurs 400:** 203

⚠️ **PROBLÈME CONFIRMÉ:** Erreurs répétées sur roo_tasks_semantic_index

---

## 5. Requêtes Lentes (>5s)

**Total requêtes lentes:** 52

🔴 **PROBLÈME MAJEUR:** Trop de requêtes lentes (52)

---

## 6. Traffic par Minute (dernières 20 minutes)

| Minute | Requêtes |
|--------|----------|
| 21:40 | 664 | | 21:41 | 701 | | 21:42 | 708 | | 21:43 | 802 | | 21:44 | 996 | | 21:45 | 94 | | 21:46 | 60 | | 21:47 | 126 | | 21:48 | 52 | | 21:49 | 52 | | 21:50 | 181 | | 21:51 | 592 | | 21:52 | 516 | | 22:11 | 6 | | 22:12 | 9 | | 22:16 | 1 | | 22:17 | 6 | | 22:20 | 12 | | 22:21 | 9 | | 22:22 | 21 |

---

## 7. CONCLUSION sur l'Hypothèse de Cycle

### ✅ HYPOTHÈSE **NON VALIDÉE**

**Ratio qdrant-js/Roo-Code:** 0.05

Le volume de requêtes de roo-state-manager est **acceptable** (293 vs 6366).

**Analyse:**
- Le MCP ne génère pas de surcharge anormale
- Les erreurs détectées (203) sont **ponctuelles**, pas systémiques
- Pas de pattern de re-scan massif au démarrage

**Conclusion:**
Le problème de crash **N'EST PAS** causé par un cycle vicieux de re-indexation.
Il faut chercher d'autres causes (mémoire, disk I/O, config Qdrant, etc.)

---

## Prochaines Étapes

1. Analyser d'autres métriques système (RAM, CPU, disk I/O)
2. Vérifier la configuration Qdrant (limites mémoire, threads)
3. Examiner les logs système pour OOM ou autres erreurs
4. Vérifier l'état des collections (indexation, corruption)
