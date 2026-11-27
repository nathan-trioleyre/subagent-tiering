# subagent-tiering

Un petit framework pour **Claude Code** qui réduit la consommation de tokens. Il fait tourner chaque sous-agent sur un modèle et un effort adaptés à sa tâche, au lieu d'hériter du modèle de la session (souvent Opus).
Il s'applique à **tous les sous-agents**, quel que soit le déclencheur : Claude lui-même, un skill, un plugin (Superpowers ou autre), un workflow, une commande slash.

Il s'installe dans la config **globale** (`~/.claude`) : il fonctionne dans tous les projets sans rien ajouter aux dépôts.

> Anciennement `claude-model-router`. Le nom a changé pour éviter un conflit avec un projet homonyme sans rapport, qui utilise les mêmes balises dans CLAUDE.md. L'installeur migre automatiquement une ancienne installation.

## Comment ça marche

| Couche | Mécanisme | Nature |
|---|---|---|
| Réglages natifs | `env` dans `settings.json` : `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`, `CLAUDE_CODE_SUBAGENT_EFFORT=medium`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3` | **Technique.** Modèle et effort par défaut des sous-agents (quand rien d'autre ne les fixe), et 3 sous-agents simultanés au maximum. |
| Agent `Explore` remplacé | `~/.claude/agents/Explore.md` : Haiku, effort faible, `maxTurns: 25`, `omitClaudeMd`, outils de lecture seulement | **Technique.** L'Explore intégré tourne sur le modèle de la session. Notre version prend sa place partout, y compris quand un plugin l'appelle. |
| Garde-fou | hook `PreToolUse` sur `Agent`/`Task` | **Technique.** Bloque tout sous-agent lancé sans `model` explicite (sauf ceux qui fixent leur modèle dans leur fichier) et renvoie la grille des niveaux à Claude. |
| Modèle par défaut | `model: "sonnet"` dans `settings.json` (`settings/settings.json`) | **Technique** pour le CLI. Dans l'application de bureau, le sélecteur de modèle garde son propre choix. |
| Règles | bloc balisé dans `~/.claude/CLAUDE.md` | **Consigne.** Quand ne pas déléguer, et quel niveau choisir. Les instructions de l'utilisateur passent avant celles des plugins. |

Ordre de priorité officiel pour le modèle d'un sous-agent :
1. le `model` précisé au lancement ;
2. le `model:` du fichier de l'agent ;
3. `CLAUDE_CODE_SUBAGENT_MODEL` ;
4. le modèle de la session.

Pour l'effort, c'est le même principe avec `CLAUDE_CODE_SUBAGENT_EFFORT`. Voir la [doc sous-agents](https://code.claude.com/docs/en/sub-agents).

### Les niveaux
| Niveau | `model` | `effort` | Pour |
|---|---|---|---|
| bas de gamme | `haiku` | `low` | recherche, lecture, résumé, modifications mécaniques avec une spec complète |
| intermédiaire (défaut) | `sonnet` | `medium` | implémentation, intégration, débogage, relecture classique |
| haut de gamme | `opus` | `medium` | architecture, relecture délicate (concurrence, sécurité), correctif qui a échoué 3 fois ou plus |

Mesuré sur une même petite tâche, sur Haiku dans les deux cas : environ 57 000 tokens avec `general-purpose`, contre environ 19 000 avec un agent léger en lecture seule. Le nombre d'outils chargés pèse autant que le modèle.

## Prérequis
- Claude Code **v2.1.315 ou plus récent**, pour `CLAUDE_CODE_SUBAGENT_EFFORT`. Les autres réglages fonctionnent sur des versions antérieures.
- **Python 3.9+** pour le hook `guard.py` (et pour `install.sh` sur macOS/Linux). Sans Python, le reste s'installe quand même sous Windows et l'installeur affiche un avertissement.

## Installation

**Windows (PowerShell)**
```powershell
git clone <url-du-repo> subagent-tiering
cd subagent-tiering
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

**macOS / Linux**
```bash
git clone <url-du-repo> subagent-tiering
cd subagent-tiering
./install.sh
```

Relance tes sessions Claude Code ensuite.

Pour mettre à jour : `git pull`, puis relance le script. On peut le relancer sans créer de doublon. Ton `config.json` est conservé.

Ton contenu existant est préservé :
- **`CLAUDE.md`** : seul le bloc entre `<!-- subagent-tiering:start -->` et `<!-- subagent-tiering:end -->` est géré.
- **`settings.json`** : il est fusionné (tes autres hooks et variables sont gardés), et une sauvegarde `settings.json.bak` est faite à chaque fois.
- **Un `Explore.md` à toi** : il est sauvegardé en `Explore.md.bak`, puis restauré à la désinstallation.

## Désinstallation
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```
```bash
./install.sh --uninstall
```

## Réglages (`~/.claude/subagent-tiering/config.json`)
```json
{
  "mode": "block",
  "exemptAgentTypes": ["fork", "statusline-setup", "claude-code-guide"]
}
```
- `mode` :
  - `block` (défaut) : refuse les lancements sans modèle ;
  - `warn` : laisse passer, mais rappelle la grille à Claude.
- Les agents dont le fichier (`~/.claude/agents/*.md` ou `.claude/agents/*.md` du projet) fixe un `model:` sont exemptés automatiquement. C'est le cas d'`Explore`.
- Pour les agents de plugins (`plugin:agent`), le garde-fou ne voit pas leur fichier. Il demande donc un modèle explicite, et ce modèle remplace celui de l'agent.

## Personnaliser
- **Règles** : `rules/CLAUDE.md`, ainsi que le texte de rappel dans `hooks/guard.py`.
- **Réglages natifs** : `settings/env.json`.
- **Agents** : `agents/*.md`.

Relance le script d'installation après chaque modification.

## Tests
```bash
python -m unittest discover -s tests -v
```

## Réglages manuels recommandés (à refaire sur chaque PC)
L'installeur applique tout ce qui vit dans `~/.claude`. Les réglages ci-dessous dépendent de l'application de bureau ou de ton compte claude.ai : aucun script ne peut les appliquer.

| Réglage | Où | Pourquoi |
|---|---|---|
| Choisir **Sonnet** dans le sélecteur de modèle | zone de message du Code tab | Le sélecteur retient son propre choix, qui peut primer sur la clé `model` installée. |
| Désactiver les **suggestions de prompt** | Paramètres → Claude Code | Chaque suggestion est une requête de plus au modèle. |
| Désactiver le **navigateur intégré** si tu utilises Claude in Chrome | Paramètres → Claude Code → Browser | Une vingtaine d'outils chargés dans chaque session. |
| Couper les **connecteurs** inutilisés (ex. Meetings) | menu **+** → Connecteurs | Leurs instructions et la liste de leurs outils sont chargées dans chaque session. |
| **Superpowers** activé seulement pour les gros chantiers | paramètres des plugins de claude.ai | Il ajoute sa démarche (réflexion, relectures, sous-agents) à chaque tâche. |

Les réglages liés au compte claude.ai (plugins, connecteurs) peuvent déjà suivre ton compte d'un PC à l'autre. Vérifie-les quand même.

## Grille de choix pour la session principale
Les réglages ci-dessus ne concernent que les sous-agents. Le modèle de la session principale, c'est toi qui le choisis :

| Type de tâche | Modèle / effort |
|---|---|
| Question rapide, renommage, petite correction | Haiku, low |
| Recherche, doc, résumé, script simple | Sonnet, low |
| Dev courant | **Sonnet, medium** ← défaut conseillé |
| Bug tordu, architecture, gros refacto | Opus, medium |
| Très dur, quand Opus medium a échoué | Opus, high |

L'alias de modèle `opusplan` utilise Opus pour planifier et Sonnet pour exécuter.

## Pistes
- En faire un plugin Claude Code, pour l'installer en une seule commande.
- Corriger automatiquement le modèle au lieu de bloquer, via un hook `agent.spawn` côté mods.
