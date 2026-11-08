#include <assert.h>
#include <stdio.h>
#include "../WaveGrid.h"

static void check(long c, long r, long w, long h, long cols, long rows,
                  long waveCols, long waveRows, long expectedC, long expectedR) {
    Wave26GridCell cell = Wave26MapGridSpan(c, r, w, h, cols, rows, waveCols, waveRows);
    assert(cell.column == expectedC && cell.row == expectedR);
}

int main(void) {
    // Every standard iPhone/iPad cell retains its existing wave coordinates.
    long layouts[][2] = {{4, 6}, {5, 6}, {6, 5}};
    for (unsigned i = 0; i < sizeof(layouts) / sizeof(layouts[0]); i++) {
        long cols = layouts[i][0], rows = layouts[i][1];
        for (long c = 0; c < cols; c++)
            for (long r = 0; r < rows; r++)
                check(c, r, 1, 1, cols, rows, cols, rows, c, r);
    }
    // Small, medium and large widgets at opposite ends of the page.
    check(0, 0, 2, 2, 4, 6, 4, 6, 1, 1);
    check(2, 4, 2, 2, 4, 6, 4, 6, 2, 4);
    check(0, 0, 4, 2, 4, 6, 4, 6, 1, 1);
    check(0, 2, 4, 4, 4, 6, 4, 6, 1, 2);
    check(0, 0, 2, 2, 5, 6, 5, 6, 1, 1);
    check(4, 3, 2, 2, 6, 5, 6, 5, 4, 3);
    // Zoomed/custom grids retain both endpoints and map their centers.
    check(0, 0, 1, 1, 4, 5, 4, 6, 0, 0);
    check(3, 4, 1, 1, 4, 5, 4, 6, 3, 5);
    check(2, 3, 1, 1, 6, 8, 4, 6, 1, 2);
    // Degenerate and clipped widget spans stay within the logical grid.
    check(3, 5, 20, 20, 4, 6, 4, 6, 3, 5);
    check(0, 0, 0, 0, 4, 6, 4, 6, 0, 0);
    puts("Grid checks passed: stock/zoomed/custom grids and widget spans.");
}
