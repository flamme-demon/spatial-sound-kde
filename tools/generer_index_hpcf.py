#!/usr/bin/env python3
"""Genere l'index des filtres de correction de casque (HpCF) publies par AutoEQ.

AutoEQ compte plus de 50 000 fichiers : impossible de les embarquer. On indexe
donc uniquement les FIR a phase minimale en 48 kHz — notre frequence de travail,
ce qui evite tout reechantillonnage — et le WAV est telecharge a la demande.

L'arborescence est parcourue **source par source** et non d'un seul appel
recursif : sur ce depot, l'API GitHub tronque la reponse globale (elle renvoie
truncated=true) meme authentifiee, ce qui produirait un index incomplet sans
aucun signe visible. Le script echoue bruyamment si une sous-arborescence est
tronquee a son tour.

Le chemin n'est pas stocke : il se reconstruit a partir des trois champs, ce qui
divise la taille de l'index par deux.

    results/{source}/{categorie}/{nom}/{nom} minimum phase 48000Hz.wav

Usage : python3 tools/generer_index_hpcf.py > share/hpcf-index.tsv
"""
import json
import subprocess
import sys
import urllib.request

DEPOT = "jaakkopasanen/AutoEq"
BRANCHE = "master"
SUFFIXE = " minimum phase 48000Hz.wav"

_gh = None


def api(chemin):
    """Interroge l'API GitHub, via gh si disponible (quota bien plus large)."""
    global _gh
    if _gh is None:
        _gh = subprocess.call(["sh", "-c", "command -v gh >/dev/null"]) == 0
    if _gh:
        out = subprocess.run(["gh", "api", chemin], capture_output=True, text=True)
        if out.returncode == 0:
            return json.loads(out.stdout)
        print(f"  gh a echoue sur {chemin}, repli sur HTTP anonyme", file=sys.stderr)
    req = urllib.request.Request(
        f"https://api.github.com/{chemin}",
        headers={"Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def sous_arbre(sha, etiquette):
    d = api(f"repos/{DEPOT}/git/trees/{sha}?recursive=1")
    if d.get("truncated"):
        sys.exit(f"sous-arborescence « {etiquette} » tronquee : index incomplet, abandon.")
    return d["tree"]


def main():
    racine = api(f"repos/{DEPOT}/git/trees/{BRANCHE}")
    resultats = next((e for e in racine["tree"]
                      if e["path"] == "results" and e["type"] == "tree"), None)
    if not resultats:
        sys.exit("dossier « results » introuvable dans le depot AutoEQ.")

    sources = [e for e in api(f"repos/{DEPOT}/git/trees/{resultats['sha']}")["tree"]
               if e["type"] == "tree"]
    print(f"{len(sources)} sources de mesure", file=sys.stderr)

    lignes = []
    for s in sources:
        source = s["path"]
        n = 0
        for e in sous_arbre(s["sha"], source):
            if e["type"] != "blob" or not e["path"].endswith(SUFFIXE):
                continue
            parts = e["path"].split("/")   # categorie / nom / fichier
            if len(parts) != 3:
                continue
            categorie, nom, fichier = parts
            # Dossier et fichier doivent porter le meme nom, sinon le chemin
            # n'est pas reconstructible et l'entree serait inutilisable.
            if fichier != nom + SUFFIXE:
                continue
            if "\t" in nom or "\t" in source or "\t" in categorie:
                continue
            lignes.append((nom, categorie, source))
            n += 1
        print(f"  {source:<24} {n:>5}", file=sys.stderr)

    lignes.sort(key=lambda x: (x[0].lower(), x[2].lower()))
    print("# nom\tcategorie\tsource — genere par tools/generer_index_hpcf.py")
    for nom, categorie, source in lignes:
        print(f"{nom}\t{categorie}\t{source}")
    print(f"TOTAL {len(lignes)} entrees", file=sys.stderr)


if __name__ == "__main__":
    main()
