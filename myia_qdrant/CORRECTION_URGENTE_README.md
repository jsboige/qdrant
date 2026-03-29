# 🚨 CORRECTION URGENTE HNSW - INSTRUCTIONS IMMÉDIATES

## SITUATION
- **58 collections sur 59** ont `max_indexing_threads=0` (HNSW corrompu)
- Overload systématique lors de l'indexation Roo
- Recherche sémantique inutilisable → redémarrages constants

## CORRECTION EN 1 COMMANDE

```powershell
cd myia_qdrant
.\scripts\diagnostics\20251015_URGENCE_fix_now.ps1
```

**Ce script fait TOUT automatiquement**:
1. ✅ Vérifie Qdrant accessible
2. ✅ Simulation rapide (sécurité)
3. ✅ Corrige les 58 collections (0→16 threads)
4. ✅ Redémarre Qdrant
5. ✅ Valide la correction

**Durée estimée**: 15-30 minutes

---

## OPTIONS AVANCÉES

### Mode Ultra-Rapide (skip simulation)
⚠️ ATTENTION: Plus risqué mais plus rapide
```powershell
.\scripts\diagnostics\20251015_URGENCE_fix_now.ps1 -SkipDryRun
```

### Mode Batch Petit (plus stable)
Si la correction échoue, essayez avec des petits batch:
```powershell
.\scripts\diagnostics\20251015_URGENCE_fix_now.ps1 -SmallBatch
```

---

## QUE FAIRE EN CAS D'ÉCHEC

### Si le script échoue
```powershell
# 1. Vérifier les logs
docker logs qdrant_production --tail 100

# 2. Relancer avec mode force
.\scripts\diagnostics\20251015_fix_hnsw_corruption_batch.ps1 -Force

# 3. Si toujours problème, correction manuelle
# Voir: docs/diagnostics/20251015_DIAGNOSTIC_OVERLOAD_HNSW_CORRUPTION.md
```

### Si container ne redémarre pas
```powershell
docker-compose -f docker-compose.production.yml down
docker-compose -f docker-compose.production.yml up -d
```

---

## VALIDATION POST-CORRECTION

### Testez l'indexation Roo
1. Ouvrez un workspace dans VS Code
2. Lancez l'indexation Roo
3. Vérifiez que le container reste stable

### Surveillez les performances
```powershell
.\scripts\diagnostics\20251015_monitor_overload_realtime.ps1 -ContinuousMode
```

**Attendu après correction**:
- ✅ Indexation de 10+ workspaces sans redémarrage
- ✅ CPU stable (<50% pendant indexation)
- ✅ Temps de réponse recherche: <50ms
- ✅ Pas de freeze/timeout

---

## BACKUPS

Tous les backups de configuration sont dans:
```
myia_qdrant/diagnostics/hnsw_backups/
```

En cas de problème grave, les backups permettent un rollback.

---

## SUPPORT

**Documentation complète**:
- [`docs/diagnostics/20251015_DIAGNOSTIC_OVERLOAD_HNSW_CORRUPTION.md`](docs/diagnostics/20251015_DIAGNOSTIC_OVERLOAD_HNSW_CORRUPTION.md)

**Scripts disponibles**:
- `20251015_URGENCE_fix_now.ps1` - Correction automatique complète
- `20251015_fix_hnsw_corruption_batch.ps1` - Correction manuelle par batch
- `20251015_monitor_overload_realtime.ps1` - Monitoring performance
- `analyze_collections.ps1` - Diagnostic état collections

---

## FAQ RAPIDE

**Q: La correction est-elle réversible?**  
R: Oui, backups automatiques avant chaque modification.

**Q: Vais-je perdre des données?**  
R: Non, la correction modifie uniquement la configuration HNSW, pas les données.

**Q: Combien de temps ça prend?**  
R: 15-30 minutes pour 58 collections.

**Q: Puis-je continuer à utiliser Qdrant pendant?**  
R: Non recommandé. Le script gère le redémarrage automatiquement.

**Q: Et si ça ne fonctionne toujours pas après?**  
R: Contact pour diagnostic approfondi - mais 95% de chances que ça résolve.

---

🎯 **ACTION IMMÉDIATE**: Lancez `.\scripts\diagnostics\20251015_URGENCE_fix_now.ps1`