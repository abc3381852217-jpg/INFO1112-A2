# AI acknowledgement:
# Plotting code created with assistance from ChatGPT (OpenAI).
# Population data is extracted from the ABS CSV using Bash.

import csv
import sys
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

years = []
populations = []

with open(sys.argv[1], newline="") as file:
    reader = csv.reader(file)

    for row in reader:
        if len(row) != 2:
            continue

        years.append(int(row[0]))
        populations.append(int(row[1]))

if not years:
    print("Error: No population data found")
    sys.exit(1)

plt.plot(years, populations, marker="o")

plt.xlabel("Year")
plt.ylabel("Population")
plt.title("NSW Population")
plt.xticks(years)
plt.ticklabel_format(style="plain", axis="y")

plt.grid(True)
plt.tight_layout()

plt.savefig(sys.argv[2])
plt.close()
