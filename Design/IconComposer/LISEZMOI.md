# Calques pour Icon Composer

Calques de l'icône d'Octopus pour Icon Composer (macOS 26), générés par `make_layers.py`.
Tous sur le même canevas de 1024 × 1024, à pleine taille : ils se superposent sans réglage.
L'icône elle-même est `Octopus/AppIcon.icon` (à ouvrir dans Icon Composer pour l'ajuster).

| Fichier | Contenu | Dans l'icône |
|---|---|---|
| `octopus-silhouette.svg` | Silhouette de la pieuvre (source, en noir) | Lue par le script |
| `1-fond.svg` | Dégradé bleu nuit | Référence : l'icône utilise le dégradé de fond d'Icon Composer |
| `2-pieuvre.svg` | Pieuvre en dégradé blanc glacé → cyan | Groupe « Pieuvre » |

Pas de coins arrondis, d'ombre ni de reflet : macOS les ajoute lui-même, et adapte l'icône
aux styles clair, sombre, transparent et teinté.

    python3 Design/IconComposer/make_layers.py
